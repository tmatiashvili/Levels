import Foundation
import LevelsModel
import Synchronization
import Testing
@testable import LevelsNet

private let rPhone = DeviceID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000E1")!)
private let rMac = DeviceID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000E2")!)
private let rT0 = Date(timeIntervalSince1970: 1_800_000_000)

private func phone(_ level: Int?, at: Date, charging: Bool = false, lowPower: Bool? = false) -> DeviceBattery {
    DeviceBattery(id: rPhone, name: "iPhone", kind: .iphone, level: level, isCharging: charging, isPluggedIn: charging,
                  isLowPowerMode: lowPower, updatedAt: at)
}

@Suite("iPhone reading upload: when the Mac needs this iPhone's reading")
struct ReadingUploadPolicyTests {
    @Test func nothingAcceptedYetUploads() {
        #expect(ReadingUploadPolicy.shouldUpload(phone(60, at: rT0), last: nil, now: rT0))
    }

    @Test func unknownLevelNeverUploads() {
        // UIDevice −1 (monitoring not on yet) must not overwrite the Mac's last good level.
        #expect(!ReadingUploadPolicy.shouldUpload(phone(nil, at: rT0), last: nil, now: rT0))
    }

    @Test func changedValueUploadsAtOnce() {
        let last = UploadedReading(phone(60, at: rT0), sentAt: rT0)
        #expect(ReadingUploadPolicy.shouldUpload(phone(59, at: rT0 + 5), last: last, now: rT0 + 5))
        #expect(ReadingUploadPolicy.shouldUpload(phone(60, at: rT0 + 5, charging: true), last: last, now: rT0 + 5))
        #expect(ReadingUploadPolicy.shouldUpload(phone(60, at: rT0 + 5, lowPower: true), last: last, now: rT0 + 5))
    }

    @Test func unchangedWaitsFiveMinutes() {
        let last = UploadedReading(phone(60, at: rT0), sentAt: rT0)
        #expect(!ReadingUploadPolicy.shouldUpload(phone(60, at: rT0 + 299), last: last, now: rT0 + 299))
        #expect(ReadingUploadPolicy.shouldUpload(phone(60, at: rT0 + 300), last: last, now: rT0 + 300))
    }

    @Test func notNewerNeverUploads() {
        // The 14:52 case: a stale cached record must not be re-sent as if it were new.
        let last = UploadedReading(phone(60, at: rT0), sentAt: rT0)
        #expect(!ReadingUploadPolicy.shouldUpload(phone(60, at: rT0), last: last, now: rT0 + 3600))
        #expect(!ReadingUploadPolicy.shouldUpload(phone(55, at: rT0 - 60), last: last, now: rT0 + 3600))
    }

    @Test func alreadyUploadedCopyIsRecognised() {
        let last = UploadedReading(phone(60, at: rT0), sentAt: rT0)
        #expect(ReadingUploadPolicy.isAlreadyUploaded(phone(60, at: rT0), last: last))
        #expect(!ReadingUploadPolicy.isAlreadyUploaded(phone(60, at: rT0 + 1), last: last))
        #expect(!ReadingUploadPolicy.isAlreadyUploaded(phone(59, at: rT0), last: last))
        #expect(!ReadingUploadPolicy.isAlreadyUploaded(phone(60, at: rT0), last: nil))
    }
}

@Suite("iPhone reading upload: the shared memory")
struct UploadedReadingMemoryTests {
    @Test func keepsTheNewestAccepted() {
        let memory = UploadedReadingMemory.inMemory()
        memory.record(phone(60, at: rT0 + 10), at: rT0 + 11)
        memory.record(phone(70, at: rT0), at: rT0 + 12)  // older reading finished later: ignored
        #expect(memory.load()?.level == 60)
        memory.clear()
        #expect(memory.load() == nil)
    }

    @Test func survivesInUserDefaults() {
        let suite = "levels-upload-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        UploadedReadingMemory(suiteName: suite).record(phone(42, at: rT0), at: rT0 + 1)
        let other = UploadedReadingMemory(suiteName: suite)  // e.g. the widget extension
        #expect(other.load() == UploadedReading(phone(42, at: rT0), sentAt: rT0 + 1))
    }
}

@Suite("iPhone reading upload: HubClient.postIfNeeded (the widget's send)")
struct PostIfNeededTests {
    final class Recorder: HubTransport {
        let paths = Mutex<[String]>([])
        let status: Int
        init(status: Int = 204) { self.status = status }
        func send(_ request: HTTPRequest, to pairing: HubPairing, me: DeviceID, timeout: Duration) async throws(HubError) -> HTTPResponse {
            paths.withLock { $0.append("\(request.method) \(request.path)") }
            return HTTPResponse(status: status)
        }
    }

    let pairing = HubPairing(hubID: UUID(), hubTag: "ab12", hubDeviceID: rMac, hubName: "Mac",
                             key: Data(repeating: 1, count: 32), pairedAt: rT0)

    @Test func sendsOnceThenNotUntilChanged() async throws {
        let transport = Recorder()
        let client = HubClient(transport: transport, pairing: InMemoryClientPairingStore(pairing), me: rPhone)
        let memory = UploadedReadingMemory.inMemory()
        #expect(try await client.postIfNeeded(phone(60, at: rT0), memory: memory, now: { rT0 }))
        #expect(try await !client.postIfNeeded(phone(60, at: rT0 + 30), memory: memory, now: { rT0 + 30 }))
        #expect(try await client.postIfNeeded(phone(59, at: rT0 + 60), memory: memory, now: { rT0 + 60 }))
        #expect(try await !client.postIfNeeded(nil, memory: memory))
        #expect(transport.paths.withLock { $0 } == ["POST /v1/readings", "POST /v1/readings"])
        #expect(memory.load()?.level == 59)
    }

    @Test func refusedIsNotRemembered() async {
        let client = HubClient(transport: Recorder(status: 503), pairing: InMemoryClientPairingStore(pairing), me: rPhone)
        let memory = UploadedReadingMemory.inMemory()
        await #expect(throws: HubError.badResponse(503)) { try await client.postIfNeeded(phone(60, at: rT0), memory: memory) }
        #expect(memory.load() == nil)
    }
}
