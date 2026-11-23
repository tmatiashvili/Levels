// MAC-003 accessory reader. Platform calls live here, in the Mac app target (ADR-0010);
// the pure parsers (`HIDAccessoryParser`, `SystemProfilerBluetoothParser`) and the
// reporter are in LevelsReaders, so they run in `swift test`.
import Foundation
import IOBluetooth
import IOKit
import LevelsReaders

/// Reads accessory batteries (ADR-0015):
/// 1. Magic Mouse, Keyboard, Trackpad and other Bluetooth HID devices: the IOKit registry,
///    `AppleDeviceManagementHIDEventService` → `BatteryPercent`, `Product`, `DeviceAddress`.
/// 2. AirPods and Beats (left, right, case or single), and any other Bluetooth device that
///    `system_profiler` gives a level for: `/usr/sbin/system_profiler SPBluetoothDataType -json`.
///    Only in builds with `LEVELS_UNSANDBOXED`: the sandbox blanks that output (ADR-0013).
///
/// IOKit readings come first in the merge, so a Magic peripheral listed by both keeps its
/// 1 % IOKit level.
struct MacAccessoryReader: AccessoryBatteryReader {
    static let hidClass = "AppleDeviceManagementHIDEventService"

    func read() async -> AccessoryScan {
        let now = Date()
        let hid = HIDAccessoryParser.parse(Self.hidServices(), now: now)
        #if LEVELS_UNSANDBOXED
        let profiler: AccessoryScan = switch await SystemProfiler.bluetoothJSON() {
        case .success(let data): SystemProfilerBluetoothParser.parse(data, now: now)
        case .failure(let problem): AccessoryScan(problems: [problem.message])
        }
        return AccessoryScan.merged([hid, profiler])
        #else
        return hid
        #endif
    }

    /// HID connect and disconnect (ADR-0015: `kIOFirstMatchNotification` and
    /// `kIOTerminatedNotification` on an `IONotificationPort` on the main queue), plus
    /// Bluetooth connect and disconnect of any device (IOBluetooth, main run loop): AirPods
    /// are audio devices, so the HID notification never fires for them.
    func changes() -> AsyncStream<AccessoryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: AccessoryChange.self, bufferingPolicy: .bufferingNewest(16))
        Task { @MainActor in
            let hid = HIDMatchNotifications(continuation)
            let bluetooth = BluetoothConnectNotifications(continuation)
            continuation.onTermination = { _ in
                Task { @MainActor in
                    hid?.cancel()
                    bluetooth.cancel()
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
/// main thread, so callbacks arrive on the main run loop. Connect callbacks for devices that
/// were already connected (IOBluetooth replays them right after registering) only arm the
/// disconnect notification: the launch scan already read them.
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

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard !cancelled else { return }
        let key = device.addressString ?? ObjectIdentifier(device).debugDescription
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(disconnected(_:device:)))
        }
        guard Date().timeIntervalSince(registeredAt) > 2 else { return }  // replay of an existing connection
        continuation.yield(.bluetoothConnected)
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        let key = device.addressString ?? ObjectIdentifier(device).debugDescription
        disconnectNotifications[key] = nil
        guard !cancelled else { return }
        continuation.yield(.bluetoothDisconnected)
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

#if LEVELS_UNSANDBOXED
/// Runs `system_profiler` (absolute path, no shell) with a 5 s timeout (MAC-003 Design).
enum SystemProfiler {
    struct Problem: Error { let message: String }

    static let path = "/usr/sbin/system_profiler"
    static let timeout: TimeInterval = 5

    static func bluetoothJSON() async -> Result<Data, Problem> {
        await Task.detached(priority: .utility) { run() }.value
    }

    private static func run() -> Result<Data, Problem> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(Problem(message: "system_profiler: could not start"))
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        if process.terminationReason == .uncaughtSignal {
            return .failure(Problem(message: "system_profiler: timed out after 5 s"))
        }
        guard process.terminationStatus == 0 else {
            return .failure(Problem(message: "system_profiler: exit status \(process.terminationStatus)"))
        }
        return .success(data)
    }
}
#endif
