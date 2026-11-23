import Foundation
import LevelsModel
import os

/// Who sent a request, as proven by the TLS-PSK handshake (NET-001 R5).
public enum HubCaller: Sendable, Equatable {
    case device(DeviceID)
    /// Identity `pair`: only `POST /v1/pair` (NET-002 R4).
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
    /// `DELETE /v1/pairing` (NET-002 R9).
    func forget(_ id: DeviceID) async
    func isPaired(_ id: DeviceID) -> Bool
    /// `POST /v1/pair` (NET-002 R5).
    func pair(_ request: PairRequest) async throws(PairError) -> PairResponse
    /// Every authenticated device request: confirms a pending pairing (NET-002 R7) and
    /// records "last seen".
    func seen(_ id: DeviceID) async
}

/// The routes of NET-001 R4 and NET-002 R5. Tests drive it with plain requests.
public actor HubRouter {
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "hub")

    private let backend: any HubBackend
    private let now: @Sendable () -> Date
    /// Returns a sleep that ends `duration` after the call (deadline fixed at the call).
    private let timer: @Sendable (Duration) -> @Sendable () async throws -> Void

    public init<C: Clock<Duration>>(backend: any HubBackend, now: @escaping @Sendable () -> Date = Date.init, clock: C = ContinuousClock()) {
        self.backend = backend
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
        ]
        guard let allowed = methods[request.path] else { return HTTPResponse(status: 404) }
        guard allowed.contains(request.method) else { return HTTPResponse(status: 405) }

        guard case .device(let id) = caller else {
            return request.path == HubProtocol.Path.pair ? await pair(request) : HTTPResponse(status: 403)
        }
        if request.path == HubProtocol.Path.pair { return HTTPResponse(status: 403) }
        await backend.seen(id)
        switch request.path {
        case HubProtocol.Path.snapshot: return await snapshot(request)
        case HubProtocol.Path.readings: return await readings(request, from: id)
        case HubProtocol.Path.devicesMe:
            await backend.removeRecord(id)
            return HTTPResponse(status: 204)
        default:  // HubProtocol.Path.pairing
            await backend.forget(id)
            return HTTPResponse(status: 204, headers: ["connection": "close"])
        }
    }

    // MARK: GET /v1/snapshot (R4, R8, R11)

    private func snapshot(_ request: HTTPRequest) async -> HTTPResponse {
        let changes = backend.changes()  // subscribe before reading, so no change is missed
        guard let current = await backend.snapshot() else { return HTTPResponse(status: 503) }
        let tag = HubWire.etag(for: current.devices)
        guard request.header("if-none-match") == tag else { return ok(current, tag: tag) }
        guard let raw = request.query["wait"], let seconds = Int(raw), seconds > 0 else {
            return HTTPResponse(status: 304, headers: ["etag": tag])
        }
        let sleep = timer(min(.seconds(seconds), HubProtocol.maxWait))
        let backend = backend
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

    static func status(for error: PairError) -> Int {
        switch error {
        case .hubFull: 409
        case .tooManyTries: 423
        case .refused, .wrongCode: 403
        case .notReachable, .timedOut: 503
        }
    }
}
