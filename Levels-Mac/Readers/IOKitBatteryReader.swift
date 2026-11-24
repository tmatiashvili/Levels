// MAC-002 IOKit reader. Lives in the Mac app target, not Shared: ADR-0010 keeps platform
// readers in the app targets (and MAC-002 lists only Levels-Mac). The pure mapping it
// uses, `MacPowerMapper`, is in LevelsReaders so AC1–AC3 run in `swift test`.
import Foundation
import IOKit.ps
import LevelsReaders

/// Reads the Mac's internal battery through IOKit power sources (MAC-002 R1–R5, R10).
/// Never throws; a failed read returns level `nil`, `.unknown`, which the reporter drops.
struct IOKitBatteryReader: BatteryReader {
    func read() async -> BatteryReading { Self.readNow() }

    /// IOPS change notifications (R6b) merged with Low Power Mode changes (R6c). Each
    /// element is a fresh read; bursts collapse to the newest one.
    func changes() -> AsyncStream<BatteryReading> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in await PowerSourceChanges.stream() {
                            continuation.yield(Self.readNow())
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                            continuation.yield(Self.readNow())
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// IOPS reads are cheap and synchronous (MAC-002 Design, builder's call).
    static func readNow() -> BatteryReading {
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled  // R4
        return MacPowerMapper.reading(from: descriptions(), lowPowerMode: lowPowerMode, now: Date())
    }

    /// One description per power source, or `nil` when IOPS answered nothing (R10).
    static func descriptions() -> [[String: Any]]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        return list.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }
    }
}

/// Bridges the IOPS run-loop notification to Swift concurrency (MAC-002 Design rules 1–5).
enum PowerSourceChanges {
    /// Holds the continuation the C callback yields to. `Continuation` is `Sendable`,
    /// so the box is too (rule 1: no `@unchecked`).
    private final class Box: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    /// The run-loop source and the retained box context. Main-actor isolated, so it is
    /// `Sendable` and teardown runs where the source was added (rule 4).
    @MainActor private final class Registration {
        let source: CFRunLoopSource
        let context: UnsafeMutableRawPointer
        init(source: CFRunLoopSource, context: UnsafeMutableRawPointer) {
            self.source = source
            self.context = context
        }

        func remove() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            Unmanaged<Box>.fromOpaque(context).release()
        }
    }

    /// One element per IOPS notification. Finishing the stream removes the run-loop
    /// source and releases the box (AC9).
    @MainActor static func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))  // rule 5
        let context = Unmanaged.passRetained(Box(continuation)).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            // Rule 2: yield only; no IOKit reads in the callback.
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().continuation.yield()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            Unmanaged<Box>.fromOpaque(context).release()
            continuation.finish()
            return stream
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)  // rule 3: fires while a menu tracks
        let registration = Registration(source: source, context: context)
        continuation.onTermination = { _ in
            Task { @MainActor in registration.remove() }
        }
        return stream
    }
}
