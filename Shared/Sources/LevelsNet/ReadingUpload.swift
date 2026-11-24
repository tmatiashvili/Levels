// When the iPhone sends its own reading to the Mac (`POST /v1/readings`). Every path that
// talks to the Mac (app launch and foreground, background refresh, the long-poll, Wi-Fi
// coming back, the widget's fetch) asks the same rule, against the last reading the Mac
// accepted. That value lives in the App Group, so the app and the widget extension share it.
//
// Before this, the app only sent a reading when it had just written it to its own cache. The
// cache write waits up to 60 s between level changes, and a held write was never sent after
// it landed. The widget fetched from the Mac every 30 minutes but never sent anything.
import Foundation
import LevelsModel
import Synchronization

/// The last own reading the Mac accepted (`204`), and when.
public struct UploadedReading: Sendable, Equatable, Codable {
    public var level: Int?
    public var isCharging: Bool
    public var isPluggedIn: Bool?
    public var isLowPowerMode: Bool?
    public var name: String
    /// The record's `updatedAt` (when the battery was read).
    public var readAt: Date
    /// When the Mac answered `204`.
    public var sentAt: Date

    public init(_ record: DeviceBattery, sentAt: Date) {
        level = record.level
        isCharging = record.isCharging
        isPluggedIn = record.isPluggedIn
        isLowPowerMode = record.isLowPowerMode
        name = record.name
        readAt = record.updatedAt
        self.sentAt = sentAt
    }

    /// Same level, charging flags, Low Power Mode and name; times are ignored.
    public func hasSameValues(as record: DeviceBattery) -> Bool {
        level == record.level && isCharging == record.isCharging && isPluggedIn == record.isPluggedIn
            && isLowPowerMode == record.isLowPowerMode && name == record.name
    }
}

/// The "should this reading go to the Mac now" rule. Pure.
public enum ReadingUploadPolicy {
    /// An unchanged reading is sent again once the last accepted one is this old, so the
    /// Mac's "updated" time keeps moving while the iPhone talks to it.
    public static let resendAfter: TimeInterval = 5 * 60

    /// - Returns: `false` for a reading without a level (`UIDevice` answered −1) and for one
    ///   no newer than the last accepted; `true` when nothing was accepted yet, when a value
    ///   differs, or when the last accepted one is at least ``resendAfter`` old.
    public static func shouldUpload(_ record: DeviceBattery, last: UploadedReading?, now: Date) -> Bool {
        guard record.level != nil else { return false }
        guard let last else { return true }
        guard record.updatedAt > last.readAt else { return false }
        if !last.hasSameValues(as: record) { return true }
        return now.timeIntervalSince(last.sentAt) >= resendAfter || now < last.sentAt
    }

    /// `true` when `record` is exactly what the Mac already has (same values, not newer):
    /// a queued copy of it can be dropped without sending.
    public static func isAlreadyUploaded(_ record: DeviceBattery, last: UploadedReading?) -> Bool {
        guard let last else { return false }
        return last.hasSameValues(as: record) && record.updatedAt <= last.readAt
    }
}

/// Where ``UploadedReading`` is kept: App Group `UserDefaults` under ``key`` in the app and the
/// widget, memory only in tests. Cleared on a new pairing and on Forget.
public final class UploadedReadingMemory: Sendable {
    public static let key = "net.lastUpload"

    private struct Suite: Sendable { var name: String? }
    private let suite: Suite?
    private let memory = Mutex<UploadedReading?>(nil)

    /// - Parameter suiteName: the App Group ID; `nil` uses `UserDefaults.standard`.
    public init(suiteName: String?) { suite = Suite(name: suiteName) }

    private init() { suite = nil }

    /// Memory only (tests).
    public static func inMemory() -> UploadedReadingMemory { UploadedReadingMemory() }

    public func load() -> UploadedReading? {
        guard let suite else { return memory.withLock { $0 } }
        guard let data = defaults(suite.name)?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(UploadedReading.self, from: data)
    }

    /// Records `record` as accepted at `at`. An older reading than the stored one is ignored
    /// (the app and the widget may finish out of order).
    public func record(_ record: DeviceBattery, at: Date) {
        if let last = load(), last.readAt > record.updatedAt { return }
        let value = UploadedReading(record, sentAt: at)
        guard let suite else { return memory.withLock { $0 = value } }
        if let data = try? JSONEncoder().encode(value) { defaults(suite.name)?.set(data, forKey: Self.key) }
    }

    public func clear() {
        guard let suite else { return memory.withLock { $0 = nil } }
        defaults(suite.name)?.removeObject(forKey: Self.key)
    }

    private func defaults(_ name: String?) -> UserDefaults? {
        guard let name else { return .standard }
        return UserDefaults(suiteName: name)
    }
}

extension HubClient {
    /// Sends `record` when ``ReadingUploadPolicy`` says the Mac needs it, and records it in
    /// `memory` once the Mac accepts it. Returns whether it was sent. The widget calls it on the
    /// connection it opens for its snapshot fetch, so the extra request costs one round trip.
    @discardableResult
    public func postIfNeeded(_ record: DeviceBattery?, memory: UploadedReadingMemory,
                             now: @Sendable () -> Date = Date.init) async throws(HubError) -> Bool {
        guard let record, ReadingUploadPolicy.shouldUpload(record, last: memory.load(), now: now()) else { return false }
        try await post(record)
        memory.record(record, at: now())
        return true
    }
}
