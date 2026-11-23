// NET-004 R14 variant B (lead's call 29: A + B). When the App Group cache is older than 15
// minutes, `getTimeline` asks the paired Mac itself, with the pairing key from the shared
// Keychain group and a 4 s limit. Links LevelsNet only, never LevelsSync (ADR-0003). Never
// posts and never touches the app's outbox.
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

    static func make() -> HubWidgetPlan.Fetch {
        { cached in
            let store = KeychainClientPairingStore(service: LevelsAppConfig.hubPairingService,
                                                   items: SecKeychainItems(accessGroup: LevelsAppConfig.keychainAccessGroup))
            guard store.current() != nil else {
                // The app says paired but the widget can't read the item: fall back to variant A.
                logger.notice("Widget: no Mac pairing readable from the shared Keychain; cache only (variant A)")
                return .unavailable
            }
            guard let me = cached?.ownDeviceID else { return .unavailable }
            let client = HubClient(transport: NWHubTransport(findTimeout: .seconds(2), readyTimeout: .seconds(2)),
                                   pairing: store, me: me)
            let fetched = await within(limit) { try? await client.snapshot(ifNoneMatch: nil, wait: nil) }
            guard case .changed(let snapshot, _)?? = fetched else {
                logger.notice("Widget: Mac not reached in \(limit.components.seconds, privacy: .public) s; cache marked away")
                return .failed
            }
            let now = Date()
            let merge: (inout SnapshotFile) -> Void = { file in
                file.merge(fetched: snapshot.devices, isFullFetch: true, pendingOwnIDs: [me])
                file.lastFetchAt = now
                file.syncStatus = .localOnly
            }
            if let group = LevelsAppConfig.appGroupID, let cache = SnapshotCache(appGroupID: group) {
                do {
                    let written = try cache.update { file -> SnapshotFile in merge(&file); return file }
                    logger.notice("Widget: fetched \(snapshot.devices.count, privacy: .public) records from the Mac")
                    return .fetched(written)
                } catch {
                    logger.error("Widget: cache write failed: \(String(describing: error), privacy: .public)")
                }
            }
            var file = cached ?? SnapshotFile(ownDeviceID: me)
            merge(&file)
            return .fetched(file)
        }
    }

    /// `work`'s result, or `nil` after `limit` (the request is left to finish on its own).
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
