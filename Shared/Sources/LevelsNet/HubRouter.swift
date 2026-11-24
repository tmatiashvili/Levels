import Foundation
import LevelsModel
import Synchronization
import os

/// Who sent a request, as proven by the TLS-PSK handshake (NET-001 R5).
public enum HubCaller: Sendable, Equatable {
    case device(DeviceID)
    /// Identity `pair`: only `POST /v1/pair` and `POST /v1/pair/confirm` (NET-002 R4).
    case pairing
}

/// What the routes read and write, with no Network code (NET-001 Design).
public protocol HubBackend: Sendable {
    /// Everything the Mac's cache holds; `nil` while reporting is off or the cache is unreadable.
    func snapshot() async -> HubSnapshot?
    /// Fires when the cache changes (R11). A new stream per call.
    func changes() -> AsyncStream<Void>
    /// R9, R10: merges one checked client record. `false` when nothing could be written.
    func ingest(_ record: DeviceBattery) async -> Bool
    /// `DELETE /v1/devices/me`.
    func removeRecord(_ id: DeviceID) async
    /// `PUT /v1/push-tokens`: replaces the device's push tokens (and, v2, its grant).
    func setPushUpload(_ upload: PushTokenUpload, for id: DeviceID) async -> PushUploadResult
    /// `GET /v1/push-key`: this Mac's push key and the caller's grant state; `nil` = push off
    /// on this Mac (404).
    func pushKey(for id: DeviceID) async -> PushKeyAnswer?
    /// `DELETE /v1/pairing` (NET-002 R9).
    func forget(_ id: DeviceID) async
    func isPaired(_ id: DeviceID) -> Bool
    /// `POST /v1/pair` (NET-002 R5).
    func pair(_ request: PairRequest) async throws(PairError) -> PairResponse
    /// `POST /v1/pair/confirm` (NET-002 R5a, R6a): checks the revealed key and returns only
    /// when the owner decided. Returns after "They match" (with the new key in the listener);
    /// throws `.refused` on Cancel and `.timedOut` when the window ended.
    func confirmPairing(_ request: PairConfirmRequest) async throws(PairError)
    /// Every authenticated device request: confirms a pending pairing (NET-002 R7) and
    /// records "last seen".
    func seen(_ id: DeviceID) async
}

/// What became of a `PUT /v1/push-tokens`.
public enum PushUploadResult: Sendable, Equatable {
    case stored
    /// The grant doesn't name this Mac's key or doesn't cover the tokens (400).
    case rejected
    /// Not paired yet, or the Keychain write failed (503).
    case failed
}

/// Which paired devices have a long-poll open right now (ADR-0020 Decision 5): their app is in
/// the foreground and reloads its own widgets, so the Mac doesn't push to them (PUSH-001 R54).
public final class HubPresence: Sendable {
    /// A long-poll that ended this recently still counts: the app sends the next one at once.
    public static let grace: TimeInterval = 10
    private let state = Mutex<[DeviceID: (open: Int, lastEnd: Date?)]>([:])
    public init() {}

    public func begin(_ id: DeviceID) { state.withLock { $0[id, default: (0, nil)].open += 1 } }

    public func end(_ id: DeviceID, at date: Date) {
        state.withLock { s in
            var e = s[id, default: (0, nil)]
            e.open = max(0, e.open - 1)
            e.lastEnd = date
            s[id] = e
        }
    }

    public func isLive(_ id: DeviceID, at date: Date) -> Bool {
        state.withLock { s in
            guard let e = s[id] else { return false }
            if e.open > 0 { return true }
            return e.lastEnd.map { date.timeIntervalSince($0) < Self.grace } ?? false
        }
    }
}

/// The routes of NET-001 R4 and NET-002 R5. Tests drive it with plain requests.
public actor HubRouter {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    private let backend: any HubBackend
    private let presence: HubPresence?
    private let now: @Sendable () -> Date
    /// Returns a sleep that ends `duration` after the call (deadline fixed at the call).
    private let timer: @Sendable (Duration) -> @Sendable () async throws -> Void

    public init<C: Clock<Duration>>(backend: any HubBackend, presence: HubPresence? = nil,
                                    now: @escaping @Sendable () -> Date = Date.init, clock: C = ContinuousClock()) {
        self.backend = backend
        self.presence = presence
        self.now = now
        self.timer = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    public func handle(_ request: HTTPRequest, from caller: HubCaller) async -> HTTPResponse {
        let response = await route(request, caller: caller)
        let who = switch caller {
        case .device(let id): id.recordName
        case .pairing: HubProtocol.pairIdentity
        }
        // R16: route, status and device ID only.
        Self.logger.notice("\(request.method, privacy: .public) \(request.path, privacy: .public) from \(who, privacy: .public) → \(response.status, privacy: .public)")
        return response
    }

    private func route(_ request: HTTPRequest, caller: HubCaller) async -> HTTPResponse {
        let methods: [String: Set<String>] = [
            HubProtocol.Path.snapshot: ["GET"], HubProtocol.Path.readings: ["POST"],
            HubProtocol.Path.devicesMe: ["DELETE"], HubProtocol.Path.pairing: ["DELETE"], HubProtocol.Path.pair: ["POST"],
            HubProtocol.Path.pairConfirm: ["POST"], HubProtocol.Path.pushTokens: ["PUT"], HubProtocol.Path.pushKey: ["GET"],
        ]
        guard let allowed = methods[request.path] else { return HTTPResponse(status: 404) }
        guard allowed.contains(request.method) else { return HTTPResponse(status: 405) }

        guard case .device(let id) = caller else {
            switch request.path {
            case HubProtocol.Path.pair: return await pair(request)
            case HubProtocol.Path.pairConfirm: return await confirmPairing(request)
            default: return HTTPResponse(status: 403)
            }
        }
        if request.path == HubProtocol.Path.pair || request.path == HubProtocol.Path.pairConfirm {
            return HTTPResponse(status: 403)
        }
        await backend.seen(id)
        switch request.path {
        case HubProtocol.Path.snapshot: return await snapshot(request, from: id)
        case HubProtocol.Path.readings: return await readings(request, from: id)
        case HubProtocol.Path.pushTokens: return await pushTokens(request, from: id)
        case HubProtocol.Path.pushKey: return await pushKey(request, from: id)
        case HubProtocol.Path.devicesMe:
            await backend.removeRecord(id)
            return HTTPResponse(status: 204)
        default:  // HubProtocol.Path.pairing
            await backend.forget(id)
            return HTTPResponse(status: 204, headers: ["connection": "close"])
        }
    }

    // MARK: GET /v1/snapshot (R4, R8, R11)

    private func snapshot(_ request: HTTPRequest, from id: DeviceID) async -> HTTPResponse {
        let changes = backend.changes()  // subscribe before reading, so no change is missed
        guard let current = await backend.snapshot() else { return HTTPResponse(status: 503) }
        let tag = HubWire.etag(for: current.devices)
        guard request.header("if-none-match") == tag else { return ok(current, tag: tag) }
        guard let raw = request.query["wait"], let seconds = Int(raw), seconds > 0 else {
            return HTTPResponse(status: 304, headers: ["etag": tag])
        }
        let sleep = timer(min(.seconds(seconds), HubProtocol.maxWait))
        let backend = backend
        presence?.begin(id)
        defer { presence?.end(id, at: now()) }
        let changed: HubSnapshot? = await withTaskGroup(of: HubSnapshot?.self) { group in
            group.addTask {
                try? await sleep()
                return nil
            }
            group.addTask {
                for await _ in changes {
                    if let s = await backend.snapshot(), HubWire.etag(for: s.devices) != tag { return s }
                }
                try? await sleep()  // stream ended: hold until the deadline
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let changed { return ok(changed, tag: HubWire.etag(for: changed.devices)) }
        return HTTPResponse(status: 304, headers: ["etag": tag])
    }

    private func ok(_ snapshot: HubSnapshot, tag: String) -> HTTPResponse {
        var s = snapshot
        s.generatedAt = now()
        guard let body = try? HubWire.encoder().encode(s) else { return HTTPResponse(status: 503) }
        return HTTPResponse(status: 200, headers: ["etag": tag, "content-type": "application/json"], body: body)
    }

    // MARK: POST /v1/readings (R9)

    private func readings(_ request: HTTPRequest, from id: DeviceID) async -> HTTPResponse {
        guard let header = request.header(HubProtocol.deviceHeader), DeviceID(recordName: header) == id,
              backend.isPaired(id)
        else { return HTTPResponse(status: 403) }
        guard let records = try? HubWire.decoder().decode([DeviceBattery].self, from: request.body) else {
            return HTTPResponse(status: 400)
        }
        guard records.count == 1, var record = records.first, record.id == id,
              record.kind == .iphone || record.kind == .ipad, record.hasConsistentAccessory
        else { return HTTPResponse(status: 403) }
        record.name = PairingWindow.cleanName(record.name, kind: record.kind)
        record.level = record.level.map(DeviceBattery.clampedLevel)
        record.serverModifiedAt = now()
        guard await backend.ingest(record) else { return HTTPResponse(status: 503) }
        var headers: [String: String] = [:]
        if let s = await backend.snapshot() { headers["etag"] = HubWire.etag(for: s.devices) }
        return HTTPResponse(status: 204, headers: headers)
    }

    // MARK: PUT /v1/push-tokens

    /// The caller's own token set only (the TLS identity and the header must agree), at most
    /// ``HubProtocol/maxPushTokensPerDevice``, each valid hex. Duplicates are dropped.
    private func pushTokens(_ request: HTTPRequest, from id: DeviceID) async -> HTTPResponse {
        guard let header = request.header(HubProtocol.deviceHeader), DeviceID(recordName: header) == id,
              backend.isPaired(id)
        else { return HTTPResponse(status: 403) }
        guard var upload = try? HubWire.decoder().decode(PushTokenUpload.self, from: request.body),
              HubProtocol.acceptedPushTokensVersions.contains(upload.v)
        else { return HTTPResponse(status: 400) }
        var seen = Set<PushToken>()
        upload.tokens = upload.tokens.filter { seen.insert($0).inserted }
        guard upload.tokens.count <= HubProtocol.maxPushTokensPerDevice, upload.tokens.allSatisfy(\.isValid) else {
            return HTTPResponse(status: 400)
        }
        if upload.v == 1 { upload.grant = nil; upload.grantExpiresAt = nil }
        // A grant comes with its expiry; neither alone. At most 4 KB (the relay's own limit).
        guard (upload.grant == nil) == (upload.grantExpiresAt == nil), (upload.grant?.utf8.count ?? 0) <= 4096 else {
            return HTTPResponse(status: 400)
        }
        switch await backend.setPushUpload(upload, for: id) {
        case .stored: return HTTPResponse(status: 204)
        case .rejected: return HTTPResponse(status: 400)
        case .failed: return HTTPResponse(status: 503)
        }
    }

    // MARK: GET /v1/push-key

    private func pushKey(_ request: HTTPRequest, from id: DeviceID) async -> HTTPResponse {
        guard let header = request.header(HubProtocol.deviceHeader), DeviceID(recordName: header) == id,
              backend.isPaired(id)
        else { return HTTPResponse(status: 403) }
        guard let answer = await backend.pushKey(for: id) else { return HTTPResponse(status: 404) }
        guard let body = try? HubWire.encoder().encode(answer) else { return HTTPResponse(status: 503) }
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
    }

    // MARK: POST /v1/pair (NET-002 R5)

    private func pair(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? HubWire.decoder().decode(PairRequest.self, from: request.body) else {
            return HTTPResponse(status: 400)
        }
        do {
            let answer = try await backend.pair(body)
            let data = try HubWire.encoder().encode(answer)
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: data)
        } catch let error as PairError {
            return HTTPResponse(status: Self.status(for: error))
        } catch {
            return HTTPResponse(status: 503)
        }
    }

    // MARK: POST /v1/pair/confirm (NET-002 R5a, R6a)

    private func confirmPairing(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = try? HubWire.decoder().decode(PairConfirmRequest.self, from: request.body) else {
            return HTTPResponse(status: 400)
        }
        do {
            try await backend.confirmPairing(body)
            return HTTPResponse(status: 204)
        } catch {
            return HTTPResponse(status: Self.status(for: error))
        }
    }

    static func status(for error: PairError) -> Int {
        switch error {
        case .hubFull: 409
        case .tooManyTries: 423
        case .refused, .wrongCode: 403
        case .timedOut: 408
        case .notReachable: 503
        }
    }
}
