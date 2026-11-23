import Foundation
import Synchronization
import Testing
@testable import LevelsModel

// HIS-001 AC1, AC4–AC7, AC9 and the store/codec round trips.

private let day: TimeInterval = 86_400

private func sample(_ offset: TimeInterval, level: Int = 50, charging: Bool = false, lowPower: Bool = false,
                    ends: Bool = false) -> HistorySample {
    HistorySample(date: now.addingTimeInterval(offset), level: level, isCharging: charging,
                  isPluggedIn: charging, isLowPowerMode: lowPower, endsSegment: ends)
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "his-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private final class FakeSync: BatterySyncing {
    let outcome: ReportOutcome
    init(_ outcome: ReportOutcome) { self.outcome = outcome }
    func report(_ readings: [DeviceBattery], reason: ReportReason) async -> ReportOutcome { outcome }
    var status: SyncStatus { get async { .localOnly } }
    func refresh(_ reason: RefreshReason) async -> Bool { true }
}

private func airPodsComponents(at date: Date) -> [DeviceBattery] {
    let group = UUID()
    return [AccessoryComponent.left, .right, .case].map { c in
        DeviceBattery(id: .accessory(key: "\(group)", component: c), name: "AirPods", kind: .accessory,
                      accessory: AccessoryInfo(parentDeviceID: DeviceID(UUID()), kind: .airpods, groupID: group, component: c),
                      level: 70, isCharging: c == .case, updatedAt: date)
    }
}

@Suite struct HistoryPolicyTests {
    @Test func ac1_pruneKeepsOnlyLastSevenDays() {
        let samples = stride(from: -(7 * day + hour), through: 0, by: 30 * minute).map { sample($0) }
        let pruned = HistoryPolicy.pruned(samples, now: now)
        #expect(pruned.first!.date >= now.addingTimeInterval(-7 * day))
        #expect(pruned.count == samples.filter { $0.date >= now.addingTimeInterval(-7 * day) }.count)
        #expect(pruned.count < samples.count)
    }

    @Test func ac6_unchangedWithinTenMinutesIsDropped() {
        let a = HistoryPolicy.appending(sample(-5 * minute), to: [sample(-10 * minute)], now: now)
        #expect(a.count == 1)
        let b = HistoryPolicy.appending(sample(0), to: [sample(-10 * minute)], now: now)
        #expect(b.count == 2)
    }

    @Test func ac6_lowPowerChangeIsAlwaysKept() {
        let s = HistoryPolicy.appending(sample(-1 * minute, lowPower: true), to: [sample(-2 * minute)], now: now)
        #expect(s.count == 2)
        #expect(s.last!.isLowPowerMode)
    }

    @Test func sameMinuteReplaces() {
        let s = HistoryPolicy.appending(sample(0, level: 49), to: [sample(0, level: 50)], now: now)
        #expect(s == [sample(0, level: 49)])
    }

    @Test func r4_sleepMarksTheLastSampleWhenThinned() {
        let s = HistoryPolicy.appending(sample(-2 * minute, ends: true), to: [sample(-5 * minute)], now: now)
        #expect(s.count == 1)
        #expect(s[0].endsSegment)
        // A wake right after keeps its sample: it starts a new segment.
        let w = HistoryPolicy.appending(sample(0), to: s, now: now)
        #expect(w.count == 2)
    }

    @Test func ac9_futureSampleIsDropped() {
        let s = HistoryPolicy.appending(sample(10 * minute), to: [sample(-30 * minute)], now: now)
        #expect(s.count == 1)
        let ok = HistoryPolicy.appending(sample(4 * minute), to: [sample(-30 * minute)], now: now)
        #expect(ok.count == 2)
    }

    @Test func r7_clockSetBackInsertsInOrder() {
        let s = HistoryPolicy.appending(sample(-60 * minute, level: 70), to: [sample(-90 * minute, level: 80), sample(-30 * minute, level: 60)], now: now)
        #expect(s.map(\.level) == [80, 70, 60])
    }

    @Test func r6_capsSamples() {
        let many = (0..<(HistoryPolicy.maxSamples + 50)).map { HistorySample(minute: HistorySample.minute(of: now) - 10_000 + $0 / 2, level: $0 % 100, isCharging: false) }
        #expect(HistoryPolicy.pruned(many, now: now).count == HistoryPolicy.maxSamples)
    }

    @Test func candidateFromReading() {
        var b = battery(level: nil)
        #expect(HistorySample(reading: b, reason: .heartbeat) == nil)
        b.level = 40
        b.isLowPowerMode = true
        let s = HistorySample(reading: b, reason: .sleep)!
        #expect(s.level == 40 && s.isLowPowerMode && s.endsSegment)
    }
}

@Suite struct HistoryCodecTests {
    @Test func ac4_worstCaseWeekIsUnder64KBAndRoundTrips() throws {
        let start = HistorySample.minute(of: now) - 10_080
        let samples = (0..<10_080).map {
            HistorySample(minute: start + $0, level: $0 % 101, isCharging: $0 % 3 == 0, isPluggedIn: $0 % 5 == 0,
                          isLowPowerMode: $0 % 7 == 0, endsSegment: $0 % 11 == 0)
        }
        let data = HistoryCodec.encode(samples)
        #expect(data.count < 64 * 1024)
        #expect(data.count == HistoryCodec.headerSize + 10_080 * HistoryCodec.sampleSize)
        #expect(try HistoryCodec.decode(data) == samples)
    }

    @Test func rejectsUnknownVersionAndTruncation() {
        #expect(throws: HistoryCodec.DecodeError.unsupportedVersion(2)) { try HistoryCodec.decode(Data([2, 0, 0, 0, 0])) }
        #expect(throws: HistoryCodec.DecodeError.truncated) { try HistoryCodec.decode(Data([1, 0, 0, 0, 0, 1])) }
        #expect(throws: HistoryCodec.DecodeError.empty) { try HistoryCodec.decode(Data()) }
    }

    @Test func emptyRoundTrips() throws {
        #expect(try HistoryCodec.decode(HistoryCodec.encode([])) == [])
    }
}

@Suite struct HistoryStoreTests {
    @Test func recordsPersistsAndReloads() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mac = battery(kind: .mac, level: 80, updatedAt: now - 20 * minute)
        let store = HistoryStore(directory: dir, now: { now })
        await store.record([mac], reason: .launch)
        var later = mac
        later.level = 79
        later.updatedAt = now
        await store.record([later], reason: .batteryChange)
        let reloaded = HistoryStore(directory: dir, now: { now })
        #expect(await reloaded.samples(for: mac.id).map(\.level) == [80, 79])
    }

    @Test func ac7_removeAllDeletesTheFolder() async throws {
        let dir = tempDirectory()
        let mac = battery(kind: .mac, level: 80)
        let store = HistoryStore(directory: dir, now: { now })
        await store.record([mac], reason: .launch)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        try await store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(await store.samples(for: mac.id).isEmpty)
        try await store.removeAll()  // already gone: no error
    }

    @Test func removeDeletesOneDevice() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = battery(kind: .mac), b = battery(kind: .iphone)
        let store = HistoryStore(directory: dir, now: { now })
        await store.record([a, b], reason: .launch)
        await store.remove(a.id)
        #expect(await HistoryStore(directory: dir, now: { now }).samples(for: a.id).isEmpty)
        #expect(await HistoryStore(directory: dir, now: { now }).samples(for: b.id).count == 1)
    }

    @Test func r5_pruneAllDeletesExpiredFiles() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = battery(kind: .mac, updatedAt: now - 8 * day)
        let clock = Mutex(now - 8 * day)
        let store = HistoryStore(directory: dir, now: { clock.withLock { $0 } })
        await store.record([old], reason: .launch)
        let file = dir.appending(path: "\(old.id.recordName).history")
        #expect(FileManager.default.fileExists(atPath: file.path))
        clock.withLock { $0 = now }
        await HistoryStore(directory: dir, now: { now }).pruneAll()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableFileReadsAsEmpty() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = DeviceID(UUID())
        try Data([9, 9, 9]).write(to: dir.appending(path: "\(id.recordName).history"))
        #expect(await HistoryStore(directory: dir, now: { now }).samples(for: id).isEmpty)
    }
}

@Suite struct HistoryRecordingSyncTests {
    @Test func ac5_acceptedReportRecordsMacAndThreeAirPods() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, now: { now })
        let mac = battery(kind: .mac, level: 55)
        let pods = airPodsComponents(at: now)
        let sync = HistoryRecordingSync(base: FakeSync(.uploaded), history: store, reporting: .inMemory())
        #expect(await sync.report([mac] + pods, reason: .launch) == .uploaded)
        for d in [mac] + pods { #expect(await store.samples(for: d.id).count == 1) }
        #expect(await store.samples(for: pods[2].id).first?.isCharging == true)
    }

    @Test func ac5_heldAndSkippedCount() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, now: { now })
        let mac = battery(kind: .mac, level: 55)
        _ = await HistoryRecordingSync(base: FakeSync(.held(until: now + minute)), history: store, reporting: .inMemory())
            .report([mac], reason: .batteryChange)
        #expect(await store.samples(for: mac.id).count == 1)
    }

    @Test func ac5_failedOrReportingOffRecordsNothing() async {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, now: { now })
        let mac = battery(kind: .mac, level: 55)
        _ = await HistoryRecordingSync(base: FakeSync(.failed(retryAt: nil)), history: store, reporting: .inMemory())
            .report([mac], reason: .launch)
        _ = await HistoryRecordingSync(base: FakeSync(.skipped), history: store, reporting: .inMemory(enabled: false))
            .report([mac], reason: .launch)
        #expect(await store.samples(for: mac.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
