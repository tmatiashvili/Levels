import Foundation
import Testing
@testable import LevelsModel

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LevelsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Snapshot file and cache")
struct SnapshotTests {
    @Test("R11: path, formatVersion, seconds-since-1970 dates, sorted keys, lastWritten keyed by record name")
    func r11Encoding() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        #expect(cache.fileURL.path.hasSuffix("/Levels/snapshot.json"))

        let d = battery(name: "Phone", updatedAt: Date(timeIntervalSince1970: 1000))
        try cache.update { file in
            file.devices = [d]
            file.lastWritten = [d.id: d]
            file.syncStatus = .signedOut
            file.lastFetchOutcome = .failed(reason: "offline")
        }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cache.fileURL)) as? [String: Any])
        #expect(json["formatVersion"] as? Int == 1)
        let lastWritten = try #require(json["lastWritten"] as? [String: Any])
        #expect(Array(lastWritten.keys) == [d.id.recordName])
        let device = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(device["updatedAt"] as? Double == 1000)

        let text = try String(contentsOf: cache.fileURL, encoding: .utf8)
        let keys = ["accessory", "devices", "formatVersion", "lastFetchOutcome", "lastWritten", "syncStatus"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions == positions.sorted())

        #expect(cache.read()?.devices == [d])
        #expect(cache.read()?.lastWritten == [d.id: d])
        #expect(cache.read()?.syncStatus == .signedOut)
    }

    @Test("AC11: missing, unknown formatVersion or garbage gives nil")
    func ac11Read() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        #expect(cache.read() == nil)

        try FileManager.default.createDirectory(at: cache.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"formatVersion":99,"devices":[],"lastWritten":{}}"#.utf8).write(to: cache.fileURL)
        #expect(cache.read() == nil)

        try Data([0xFF, 0x00, 0x13, 0x37]).write(to: cache.fileURL)
        #expect(cache.read() == nil)

        // Edge case "corrupt cache": the next update rewrites the file.
        try cache.update { $0.ownDeviceID = DeviceID(UUID()) }
        #expect(cache.read() != nil)
    }

    @Test("AC12: concurrent updates from two coordinators all persist", .timeLimit(.minutes(1)))
    func ac12Concurrent() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        let errors = ErrorBox()
        // Two threads, each a separate writer; every update uses its own NSFileCoordinator.
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for i in 0..<100 {
                let d = battery(name: "w\(worker)-\(i)")
                do { try cache.update { $0.devices.append(d) } } catch { errors.add(error) }
            }
        }
        #expect(errors.isEmpty)
        #expect(cache.read()?.devices.count == 200)
    }

    @Test("update throws on an unreadable file and leaves it unchanged")
    func unreadableFileNotWiped() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        let own = DeviceID(UUID())
        try cache.update { $0.ownDeviceID = own; $0.accountFingerprint = "abc" }
        let before = try Data(contentsOf: cache.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cache.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cache.fileURL.path) }

        #expect(throws: (any Error).self) { try cache.update { $0.lastFetchAt = now } }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cache.fileURL.path)
        #expect(try Data(contentsOf: cache.fileURL) == before)
        #expect(cache.read()?.ownDeviceID == own)
    }

    @Test("update never overwrites a newer formatVersion")
    func newerFormatNotOverwritten() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        try FileManager.default.createDirectory(at: cache.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"formatVersion":2,"devices":[],"lastWritten":{},"ownDeviceID":"x"}"#.utf8)
        try newer.write(to: cache.fileURL)

        #expect(throws: SnapshotCache.UpdateError.unsupportedFormatVersion(2)) {
            try cache.update { $0.lastFetchAt = now }
        }
        #expect(try Data(contentsOf: cache.fileURL) == newer)
    }

    @Test("update keeps devices sorted even when body appends out of order")
    func updateSorts() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        let mac = battery(kind: .mac, name: "Mac")
        let phoneB = battery(kind: .iphone, name: "B")
        let phoneA = battery(kind: .iphone, name: "A")
        try cache.update { $0.devices.append(contentsOf: [mac, phoneB, phoneA]) }
        #expect(cache.read()?.devices == [phoneA, phoneB, mac])
    }

    @Test("reset deletes the file")
    func reset() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = SnapshotCache(directory: dir)
        try cache.reset()
        try cache.update { $0.lastFetchAt = now }
        #expect(cache.read() != nil)
        try cache.reset()
        #expect(cache.read() == nil)
    }

    @Test("AC15 (logic only): no container or unusable directory gives nil")
    func ac15Logic() throws {
        #expect(SnapshotCache(appGroupID: "group.x", containerURL: { _ in nil }) == nil)
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A plain file where the container should be: `Levels/` can't be created.
        let file = dir.appendingPathComponent("not-a-dir")
        try Data().write(to: file)
        #expect(SnapshotCache(appGroupID: "group.x", containerURL: { _ in file }) == nil)
        let ok = SnapshotCache(appGroupID: "group.x", containerURL: { _ in dir })
        #expect(ok?.fileURL == dir.appendingPathComponent("Levels/snapshot.json"))
    }

    @Test("AC13: full fetch drops missing entries except own pending ones")
    func ac13FullFetch() {
        let a = battery(kind: .iphone, name: "A", updatedAt: now - hour)
        let b = battery(kind: .ipad, name: "B")
        let o = battery(kind: .mac, name: "O")
        var file = SnapshotFile(devices: [a, b, o])
        var newA = a
        newA.updatedAt = now
        newA.level = 20
        file.merge(fetched: [newA], isFullFetch: true, ownIDs: [o.id])
        #expect(Set(file.devices) == [newA, o])
    }

    @Test("AC14: an older fetched entry does not replace a newer cached one")
    func ac14KeepNewer() {
        let cached = battery(name: "A", level: 50, updatedAt: now)
        var fetched = cached
        fetched.updatedAt = now - minute
        fetched.level = 90
        var file = SnapshotFile(devices: [cached])
        file.merge(fetched: [fetched], isFullFetch: false, ownIDs: [])
        #expect(file.devices == [cached])
        file.merge(fetched: [fetched], isFullFetch: true, ownIDs: [])
        #expect(file.devices == [cached])
    }

    @Test("Own record: the local copy always wins over the hub's copy (owner's '1 hour ago' report)")
    func ownRecordKeepsLocalCopy() {
        let local = battery(kind: .iphone, name: "iPhone", level: 85, isCharging: true, updatedAt: now)
        // The hub echoes an older reading of this iPhone, and the same reading stamped with its own clock.
        var older = local
        older.level = 40
        older.isCharging = false
        older.updatedAt = now - hour
        var echoed = local
        echoed.serverModifiedAt = now - hour  // a hub clock behind ours would age the reading
        var future = local
        future.updatedAt = now + minute
        future.level = 10
        for hubCopy in [older, echoed, future] {
            for full in [false, true] {
                var file = SnapshotFile(devices: [local])
                file.merge(fetched: [hubCopy], isFullFetch: full, ownIDs: [local.id])
                #expect(file.devices == [local])
            }
        }
        // With no local copy yet (fresh install), the hub's copy is taken.
        var empty = SnapshotFile()
        empty.merge(fetched: [older], isFullFetch: true, ownIDs: [local.id])
        #expect(empty.devices == [older])
        // Other devices still take the newer or tied fetched copy.
        let mac = battery(kind: .mac, name: "Mac", updatedAt: now - minute)
        var newerMac = mac
        newerMac.updatedAt = now
        var file = SnapshotFile(devices: [local, mac])
        file.merge(fetched: [newerMac, older], isFullFetch: true, ownIDs: [local.id])
        #expect(Set(file.devices) == [local, newerMac])
    }

    @Test("R14: partial fetch keeps unreturned entries and adds new ones; devices sorted by kind then name")
    func partialFetchAndSort() {
        let mac = battery(kind: .mac, name: "Mac")
        let phoneB = battery(kind: .iphone, name: "b phone")
        let phoneA = battery(kind: .iphone, name: "A phone")
        var file = SnapshotFile(devices: [mac])
        file.merge(fetched: [phoneB, phoneA], isFullFetch: false, ownIDs: [])
        #expect(file.devices == [phoneA, phoneB, mac])
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []
    func add(_ e: any Error) { lock.withLock { errors.append(e) } }
    var isEmpty: Bool { lock.withLock { errors.isEmpty } }
}
