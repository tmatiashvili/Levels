// NET-004 R14 variant B (lead's call 29: A + B). When the App Group cache is older than 15
// minutes, `getTimeline` asks the paired Mac itself, with the pairing key from the shared
// Keychain group and a 4 s limit. Links LevelsNet only, never LevelsSync (ADR-0003). Never
// touches the app's outbox.
//
// On the same connection it first sends this iPhone's own reading (`POST /v1/readings`) when the
// Mac needs it (`ReadingUploadPolicy`, against the last accepted reading the app and the widget
// share in the App Group). The app runs rarely; the widget's fetch every 30 minutes was the
// only regular contact and left the Mac with the app's last reading.
//
// It first dials the Mac's last address from the App Group (the app and this widget save it
// after each Bonjour connection), then falls back to Bonjour: Bonjour plus TLS often did not
// fit in 4 s. Several widgets (Home Screen, Lock Screen) reload together; they share one fetch.
import Foundation
import LevelsModel
import LevelsNet
import LevelsWidgetKit
import Synchronization
import os

enum WidgetHubFetch {
    static let logger = Logger(subsystem: LevelsLog.subsystem, category: "widget")
    /// R14: the fetch must finish inside `getTimeline` in under 4 s.
    static let limit: Duration = .seconds(4)

    /// One fetch at a time for every widget of this process (``SharedFetch``).
    static let shared = SharedFetch<HubWidgetPlan.FetchResult>(reuseFor: 60)

    static func make() -> HubWidgetPlan.Fetch {
        { cached in await shared.run { await fetch(cached) } }
    }

    private static func fetch(_ cached: SnapshotFile?) async -> HubWidgetPlan.FetchResult {
        let started = ContinuousClock.now
        let store = KeychainClientPairingStore(service: LevelsAppConfig.hubPairingService,
                                               items: SecKeychainItems(accessGroup: LevelsAppConfig.keychainAccessGroup))
        guard store.current() != nil else {
            // The app says paired but the widget can't read the item: fall back to variant A.
            logger.notice("Widget: no Mac pairing readable from the shared Keychain; cache only (variant A)")
            return .unavailable
        }
        guard let me = cached?.ownDeviceID else { return .unavailable }
        let memory = UserDefaultsHubEndpointMemory(suiteName: LevelsAppConfig.appGroupID)
        let transport = NWHubTransport(findTimeout: .seconds(2), readyTimeout: .seconds(2), memory: memory,
                                       directTimeout: .milliseconds(1500))
        let client = HubClient(transport: transport, pairing: store, me: me)
        let toSend = ReportingSetting(suiteName: LevelsAppConfig.appGroupID).isEnabled  // SYNC-001 R15a
            ? cached?.ownRecordToSend(await WidgetOwnBattery.read()) : nil
        let uploaded = UploadedReadingMemory(suiteName: LevelsAppConfig.appGroupID)
        let fetched = await within(limit) { () -> Result<HubFetch, HubError> in
            do throws(HubError) {
                do throws(HubError) {
                    if try await client.postIfNeeded(toSend, memory: uploaded) {
                        logger.notice("Widget: sent own reading \(toSend?.level ?? -1, privacy: .public) % to the Mac")
                    }
                } catch {
                    // Not reached: the fetch below fails the same way. Refused: fetch anyway.
                    guard case .badResponse(let code) = error else { throw error }
                    logger.notice("Widget: the Mac refused the own reading (\(code, privacy: .public)); fetching anyway")
                }
                return .success(try await client.snapshot(ifNoneMatch: nil, wait: nil))
            } catch {
                return .failure(error)
            }
        }
        // Close the connection on every path: after a timeout this also ends the request
        // still running (its exchange fails once the connection is cancelled).
        await transport.reset()
        let snapshot: HubSnapshot
        switch fetched {
        case .success(.changed(let s, _))?:
            snapshot = s
        case .failure(let error)? where !Self.isUnreachable(error):
            logger.notice("Widget: the Mac answered with an error (\(String(describing: error), privacy: .public)); cache kept, not away")
            return .macError
        case .failure(let error)?:
            logger.notice("Widget: Mac not reached (\(String(describing: error), privacy: .public)) after \(elapsed(since: started), privacy: .public) ms; cache marked away")
            return .failed
        default:
            logger.notice("Widget: Mac not reached in \(limit.components.seconds, privacy: .public) s; cache marked away")
            return .failed
        }
        let now = Date()
        let merge: (inout SnapshotFile) -> Void = { file in
            file.mergeFetch(snapshot.devices, ownID: me, at: now)
        }
        if let group = LevelsAppConfig.appGroupID, let cache = SnapshotCache(appGroupID: group) {
            do {
                let written = try cache.update { file -> SnapshotFile in merge(&file); return file }
                logger.notice("Widget: fetched \(snapshot.devices.count, privacy: .public) records from the Mac in \(elapsed(since: started), privacy: .public) ms")
                return .fetched(written)
            } catch {
                logger.error("Widget: cache write failed: \(String(describing: error), privacy: .public)")
            }
        }
        var file = cached ?? SnapshotFile(ownDeviceID: me)
        merge(&file)
        return .fetched(file)
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Int64 {
        let d = ContinuousClock.now - start
        return d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }

    /// Not reached at all, as opposed to "reached, but it answered with an error".
    static func isUnreachable(_ error: HubError) -> Bool {
        switch error {
        case .notFound, .notReady, .timedOut, .localNetworkDenied, .notPaired: true
        case .handshakeRefused, .versionMismatch, .badResponse: false
        }
    }

    /// `work`'s result, or `nil` after `limit` (the caller then resets the transport, which
    /// ends the request).
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let box = ResultBox<T>()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            Task { let v = await work(); if box.claim() { c.resume(returning: v) } }
            Task { try? await Task.sleep(for: limit); if box.claim() { c.resume(returning: nil) } }
        }
    }
}

final class ResultBox<T>: Sendable {
    private let done = Mutex(false)
    func claim() -> Bool { done.withLock { d in defer { d = true }; return !d } }
}
