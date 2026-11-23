import Foundation
import os

/// The local 7-day history of this Mac and its accessories (HIS-001, lead's call 19):
/// one ``HistoryCodec`` file per device in `directory`, written atomically. Single
/// process (the Mac app); no file coordination needed.
public actor HistoryStore {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "history")
    private static let sweepInterval: TimeInterval = 3600
    static let fileExtension = "history"

    public nonisolated let directory: URL
    private let now: @Sendable () -> Date
    /// Loaded files (pruned), by device.
    private var cache: [DeviceID: [HistorySample]] = [:]
    /// Files that failed to decode (newer format, corruption). Reads treat them as empty, but
    /// only a real ``record(_:reason:)`` for that device replaces them; pruning never deletes them.
    private var unreadable: Set<DeviceID> = []
    private var lastSweep: Date?

    /// - Parameter directory: e.g. `Application Support/<bundle id>/History`.
    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    /// The Mac app's folder: `Application Support/<bundle id>/History` (R12: not the App Group).
    public static func defaultDirectory(bundleID: String?) -> URL {
        URL.applicationSupportDirectory
            .appending(path: bundleID ?? "Levels", directoryHint: .isDirectory)
            .appending(path: "History", directoryHint: .isDirectory)
    }

    /// Records one candidate per reading (R1–R7) and writes changed files.
    public func record(_ readings: [DeviceBattery], reason: ReportReason) {
        let t = now()
        for reading in readings {
            guard let sample = HistorySample(reading: reading, reason: reason) else { continue }
            let before = load(reading.id)
            let after = HistoryPolicy.appending(sample, to: before, now: t)
            guard after != before else { continue }
            cache[reading.id] = after
            write(after, for: reading.id)
        }
        if lastSweep.map({ t.timeIntervalSince($0) >= Self.sweepInterval }) ?? true {
            pruneAll()
        }
    }

    /// The last 7 days of `id`, oldest first (pruned on read, R5).
    public func samples(for id: DeviceID) -> [HistorySample] {
        let before = load(id)
        let after = HistoryPolicy.pruned(before, now: now())
        if after != before, !unreadable.contains(id) {
            cache[id] = after
            write(after, for: id)
        }
        return after
    }

    /// Several devices at once (an AirPods group's components).
    public func samples(for ids: [DeviceID]) -> [DeviceID: [HistorySample]] {
        Dictionary(ids.map { ($0, samples(for: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Prunes every file; deletes files with nothing left (R5). Runs at launch and hourly within `record`.
    public func pruneAll() {
        let t = now()
        lastSweep = t
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for url in urls where url.pathExtension == Self.fileExtension {
            guard let id = DeviceID(recordName: url.deletingPathExtension().lastPathComponent) else { continue }
            let before = load(id)
            guard !unreadable.contains(id) else { continue }  // keep a file we can't read
            let after = HistoryPolicy.pruned(before, now: t)
            if after.isEmpty { removed += 1 }
            if after != before || after.isEmpty {
                cache[id] = after
                write(after, for: id)
            }
        }
        Self.logger.info("Pruned history: \(urls.count, privacy: .public) files, \(removed, privacy: .public) removed")
    }

    /// Deletes one device's history ("Remove", R12).
    public func remove(_ id: DeviceID) {
        cache[id] = []
        unreadable.remove(id)
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Deletes the whole history folder ("Remove all my data", R12, ADR-0019 §6).
    /// A folder that is already gone is not an error.
    public func removeAll() throws {
        cache = [:]
        unreadable = []
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // already gone
        }
        Self.logger.notice("Removed all history")
    }

    // MARK: Files

    private func url(for id: DeviceID) -> URL {
        directory.appending(path: "\(id.recordName).\(Self.fileExtension)", directoryHint: .notDirectory)
    }

    private func load(_ id: DeviceID) -> [HistorySample] {
        if let cached = cache[id] { return cached }
        var samples: [HistorySample] = []
        if let data = try? Data(contentsOf: url(for: id)) {
            do {
                samples = try HistoryCodec.decode(data)
            } catch {
                unreadable.insert(id)
                Self.logger.error("Unreadable history for \(id.recordName, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        cache[id] = samples
        return samples
    }

    private func write(_ samples: [HistorySample], for id: DeviceID) {
        let url = url(for: id)
        do {
            if samples.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                return
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try HistoryCodec.encode(samples).write(to: url, options: .atomic)
            unreadable.remove(id)  // replaced by a real write
        } catch {
            // The in-memory copy keeps the samples; the next write retries.
            Self.logger.error("History write failed for \(id.recordName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

/// A ``BatterySyncing`` decorator that records each accepted report into a ``HistoryStore``
/// (HIS-001 R1): reporting on and an outcome other than `.failed`. Everything else passes through.
public struct HistoryRecordingSync: BatterySyncing {
    let base: any BatterySyncing
    let history: HistoryStore
    let reporting: ReportingSetting

    public init(base: any BatterySyncing, history: HistoryStore, reporting: ReportingSetting) {
        self.base = base
        self.history = history
        self.reporting = reporting
    }

    public func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome {
        let outcome = await base.report(readings, reason: reason)
        if case .failed = outcome { return outcome }
        if reporting.isEnabled { await history.record(readings, reason: reason) }
        return outcome
    }

    public var status: SyncStatus { get async { await base.status } }

    public func refresh(_ reason: RefreshReason) async -> Bool { await base.refresh(reason) }
}
