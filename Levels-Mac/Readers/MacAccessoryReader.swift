// MAC-003 accessory reader. Platform calls live here, in the Mac app target (ADR-0010);
// the pure parsers (`HIDAccessoryParser`, `SystemProfilerBluetoothParser`) and the
// reporter are in LevelsReaders, so they run in `swift test`.
import Foundation
import IOBluetooth
import IOKit
import LevelsReaders
import notify

/// Reads accessory batteries (ADR-0015):
/// 1. Magic Mouse, Keyboard, Trackpad and other Bluetooth HID devices: the IOKit registry,
///    `AppleDeviceManagementHIDEventService` → `BatteryPercent`, `Product`, `DeviceAddress`.
/// 2. AirPods and Beats heard by macOS, connected or only nearby, with charging:
///    `/usr/bin/pmset -g accps -xml` (macOS's accessory power sources), tied to the paired
///    device's address through the `system_profiler` device list (ADR-0015 amendment).
/// 3. AirPods and Beats (left, right, case or single), and any other Bluetooth device that
///    `system_profiler` gives a level for: `/usr/sbin/system_profiler SPBluetoothDataType -json`.
/// Sources 2 and 3 run only in builds with `LEVELS_UNSANDBOXED`: the sandbox blanks
/// `system_profiler` (ADR-0013).
///
/// The merge keeps the first reading per record: IOKit, then power sources, then
/// `system_profiler`. A Magic peripheral keeps its 1 % IOKit level; AirPods get their
/// 1 % level and charging.
struct MacAccessoryReader: AccessoryBatteryReader {
    static let hidClass = "AppleDeviceManagementHIDEventService"

    func read() async -> AccessoryScan {
        let now = Date()
        let hid = HIDAccessoryParser.parse(Self.hidServices(), now: now)
        #if LEVELS_UNSANDBOXED
        async let profilerOutput = SystemProfiler.bluetoothJSON()
        async let powerOutput = SystemProfiler.accessoryPowerSources()
        let profiler: AccessoryScan
        var paired: [PairedBluetoothDevice] = []
        switch await profilerOutput {
        case .success(let data):
            profiler = SystemProfilerBluetoothParser.parse(data, now: now)
            paired = SystemProfilerBluetoothParser.pairedDevices(data)
        case .failure(let problem):
            profiler = AccessoryScan(problems: [problem.message])
        }
        let power: AccessoryScan = switch await powerOutput {
        case .success(let data): PowerSourceAccessoryParser.parse(data, paired: paired, now: now)
        case .failure(let problem): AccessoryScan(problems: [problem.message])
        }
        // Power sources before system_profiler: 1 % levels and charging win for connected AirPods.
        return AccessoryScan.merged([hid, power, profiler])
        #else
        return hid
        #endif
    }

    /// HID connect and disconnect (ADR-0015: `kIOFirstMatchNotification` and
    /// `kIOTerminatedNotification` on an `IONotificationPort` on the main queue), plus
    /// Bluetooth connect and disconnect of any device (IOBluetooth, main run loop): AirPods
    /// are audio devices, so the HID notification never fires for them. In unsandboxed
    /// builds also AirPods level and charging changes while they are only nearby
    /// (``AccessoryPowerSourceWatch``).
    func changes() -> AsyncStream<AccessoryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AccessoryChange.self, bufferingPolicy: .bufferingNewest(16))
        Task { @MainActor in
            let hid = HIDMatchNotifications(continuation)
            let bluetooth = BluetoothConnectNotifications(continuation)
            #if LEVELS_UNSANDBOXED
            let power = AccessoryPowerSourceWatch(continuation)
            #endif
            continuation.onTermination = { _ in
                Task { @MainActor in
                    hid?.cancel()
                    bluetooth.cancel()
                    #if LEVELS_UNSANDBOXED
                    power.cancel()
                    #endif
                }
            }
        }
        return stream
    }

    /// The properties `HIDAccessoryParser` needs, one dictionary per service.
    static func hidServices() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(hidClass), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var services: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var props: [String: Any] = [:]
            for key in HIDAccessoryParser.keys {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() {
                    props[key] = value
                }
            }
            services.append(props)
        }
        return services
    }
}

/// Owns the IOKit notification port and the two notification iterators. Main-actor
/// isolated: the port delivers on the main queue and teardown runs there too.
@MainActor private final class HIDMatchNotifications {
    private final class Box: Sendable {
        let continuation: AsyncStream<AccessoryChange>.Continuation
        init(_ continuation: AsyncStream<AccessoryChange>.Continuation) { self.continuation = continuation }
    }

    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    private let context: UnsafeMutableRawPointer

    init?(_ continuation: AsyncStream<AccessoryChange>.Continuation) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        context = Unmanaged.passRetained(Box(continuation)).toOpaque()
        IONotificationPortSetDispatchQueue(port, .main)

        let callback: IOServiceMatchingCallback = { context, iterator in
            HIDMatchNotifications.drain(iterator)  // re-arms the notification
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().continuation.yield(.hid)
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // Each call consumes one reference to the matching dictionary.
            let result = IOServiceAddMatchingNotification(port, type, IOServiceMatching(MacAccessoryReader.hidClass),
                                                          callback, context, &iterator)
            guard result == KERN_SUCCESS else { continue }
            Self.drain(iterator)  // existing services: the launch scan already read them
            iterators.append(iterator)
        }
        if iterators.isEmpty {
            cancel()
            return nil
        }
    }

    nonisolated fileprivate static func drain(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return }
            IOObjectRelease(service)
        }
    }

    private var cancelled = false

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators = []
        IONotificationPortDestroy(port)
        Unmanaged<Box>.fromOpaque(context).release()
    }
}

/// IOBluetooth connect and disconnect for any device (MAC-003 triggers). Registered on the
/// main thread, but IOBluetooth may still call back on its own `coordinatorQueue`: the `@objc`
/// callbacks are `nonisolated` and hop to the main actor (a main-actor callback there trapped
/// in Swift 6's isolation check and quit the app, 2026-11-24). Connect callbacks for devices
/// that were already connected (IOBluetooth replays them right after registering) only arm
/// the disconnect notification: the launch scan already read them.
@MainActor private final class BluetoothConnectNotifications: NSObject {
    private let continuation: AsyncStream<AccessoryChange>.Continuation
    private var connectNotification: IOBluetoothUserNotification?
    /// One disconnect notification per connected device, by address.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private let registeredAt = Date()
    private var cancelled = false

    init(_ continuation: AsyncStream<AccessoryChange>.Continuation) {
        self.continuation = continuation
        super.init()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                         selector: #selector(connected(_:device:)))
        if connectNotification == nil {
            MacAppModel.logger.error("IOBluetooth connect notification unavailable; AirPods are found by the poll only")
        }
    }

    @objc private nonisolated func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let at = Date()
        let device = UncheckedSendable(device)
        Self.onMain { self.didConnect(device.value, at: at) }
    }

    @objc private nonisolated func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let objects = UncheckedSendable((notification, device))
        Self.onMain { self.didDisconnect(objects.value.0, device: objects.value.1) }
    }

    private func didConnect(_ device: IOBluetoothDevice, at: Date) {
        guard !cancelled else { return }
        let key = device.addressString ?? ObjectIdentifier(device).debugDescription
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(disconnected(_:device:)))
        }
        guard at.timeIntervalSince(registeredAt) > 2 else { return }  // replay of an existing connection
        continuation.yield(.bluetoothConnected)
    }

    private func didDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        let key = device.addressString ?? ObjectIdentifier(device).debugDescription
        disconnectNotifications[key] = nil
        guard !cancelled else { return }
        continuation.yield(.bluetoothDisconnected)
    }

    /// Runs `work` on the main actor: at once when IOBluetooth called on the main thread,
    /// else on the main queue.
    private nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values { notification.unregister() }
        disconnectNotifications = [:]
    }
}

/// IOBluetooth objects passed from its callback queue to the main actor, which alone uses them.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

#if LEVELS_UNSANDBOXED
/// Runs `system_profiler` and `pmset` (absolute paths, no shell) with a 5 s timeout
/// (MAC-003 Design).
enum SystemProfiler {
    struct Problem: Error { let message: String }

    static let path = "/usr/sbin/system_profiler"
    static let pmsetPath = "/usr/bin/pmset"
    static let timeout: TimeInterval = 5

    static func bluetoothJSON() async -> Result<Data, Problem> {
        await Task.detached(priority: .utility) {
            run(path, ["SPBluetoothDataType", "-json"], label: "system_profiler")
        }.value
    }

    /// macOS's accessory power sources (ADR-0015 amendment): AirPods left, right and case
    /// with charging, also while they are only nearby.
    static func accessoryPowerSources() async -> Result<Data, Problem> {
        await Task.detached(priority: .utility) { run(pmsetPath, ["-g", "accps", "-xml"], label: "pmset") }.value
    }

    private static func run(_ path: String, _ arguments: [String], label: String) -> Result<Data, Problem> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(Problem(message: "\(label): could not start"))
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationReason == .uncaughtSignal {
            return .failure(Problem(message: "\(label): timed out after 5 s"))
        }
        guard process.terminationStatus == 0 else {
            return .failure(Problem(message: "\(label): exit status \(process.terminationStatus)"))
        }
        return .success(data)
    }
}

/// Emits ``AccessoryChange/powerSources`` when an AirPods level or charging state changes in
/// macOS's accessory power sources, so a charging change reaches the widgets within about a
/// minute even while the AirPods are not connected. Checks on every
/// `com.apple.system.powersources` notification and on a 60 s timer (the notification is
/// not documented to cover accessories). A check runs `pmset -g accps -xml` (a few ms) and
/// compares ``PowerSourceAccessoryParser/fingerprint(_:)``; the first check only sets the
/// baseline (the launch scan already read it). Main-actor isolated: the notification and
/// the timer deliver on the main queue.
@MainActor private final class AccessoryPowerSourceWatch {
    static let notification = "com.apple.system.powersources"
    static let interval: TimeInterval = 60

    private let continuation: AsyncStream<AccessoryChange>.Continuation
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private var timer: DispatchSourceTimer?
    private var last: [String]?
    private var checking = false
    private var cancelled = false

    init(_ continuation: AsyncStream<AccessoryChange>.Continuation) {
        self.continuation = continuation
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(Self.notification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        self.token = status == NOTIFY_STATUS_OK ? token : NOTIFY_TOKEN_INVALID
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.check() } }
        timer.resume()
        self.timer = timer
        check()
    }

    private func check() {
        guard !cancelled, !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            guard case .success(let data) = await SystemProfiler.accessoryPowerSources(), !cancelled else { return }
            let current = PowerSourceAccessoryParser.fingerprint(data)
            defer { last = current }
            guard let last, last != current else { return }
            continuation.yield(.powerSources)
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        timer?.cancel()
        timer = nil
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
        token = NOTIFY_TOKEN_INVALID
    }
}
#endif
