import Foundation
import LevelsModel
import Observation

/// The list state for apps (ADR-0016 rule 2, UI-001). Reads through a ``DeviceSnapshotSource``.
@Observable @MainActor public final class DeviceListStore {
    public enum State: Equatable, Sendable {
        case loading, empty, onlyThisDevice, loaded, noICloud
        case syncError(String)
        /// Hub mode (NET-004 R1, R11): no Mac pairing; the app shows "Connect to your Mac".
        case notPaired
        /// Hub mode: rows plus a hub banner (NET-004 R4).
        case hub(HubBanner)
    }

    /// The hub banners of NET-004 R4.
    public enum HubBanner: Equatable, Sendable {
        /// "Away from your Mac. Last update <age>."
        case away(lastContactAt: Date?)
        /// Local Network permission is off (`.restricted` in hub mode).
        case localNetworkOff
        /// The Mac refused this iPhone's key (`.misconfigured(401)`).
        case forgotThisPhone
        /// Protocol versions differ (`.misconfigured(426)`).
        case updateNeeded
    }

    /// True in the iPhone's hub build (ADR-0020): statuses map per NET-004 R11, and old
    /// devices are removed on the Mac only (R8).
    public let isHubMode: Bool

    public private(set) var rows: [DeviceRowModel] = []
    /// Devices with no reading for 30 days (R14), same order as `rows`.
    public private(set) var oldRows: [DeviceRowModel] = []
    /// Hidden devices, for the settings "Hidden devices" section (R2).
    public private(set) var hiddenRows: [DeviceRowModel] = []
    public private(set) var state: State = .loading
    /// True while a user refresh runs (spinner).
    public private(set) var isRefreshing = false
    /// True after ``removeAllData()`` until ``resumeReporting()``, across relaunches (UI-002 R12
    /// banner, SYNC-001 R15a).
    public private(set) var isReportingOff: Bool
    /// This device's ID; `nil` before it registered (rename is then disabled).
    public private(set) var thisDeviceID: DeviceID?
    public private(set) var preferences: DisplayPreferences

    @ObservationIgnored private let source: any DeviceSnapshotSource
    @ObservationIgnored private let preferencesStore: any DisplayPreferencesStore
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let refreshTimeout: Duration
    @ObservationIgnored private var snapshot: SnapshotFile?
    @ObservationIgnored private var loadError: String?
    @ObservationIgnored private var refreshError: String?
    @ObservationIgnored private var dismissedError: String?

    /// - Parameters:
    ///   - now: the clock used to split off old devices (tests pass a fixed one).
    ///   - refreshTimeout: a user refresh ends its spinner after this even if the source hangs (UI-002 AC2).
    public init(source: some DeviceSnapshotSource,
                preferences: some DisplayPreferencesStore,
                now: @escaping @Sendable () -> Date = { Date() },
                refreshTimeout: Duration = .seconds(15),
                isHubMode: Bool = false) {
        self.isHubMode = isHubMode
        self.source = source
        preferencesStore = preferences
        self.preferences = preferences.load()
        isReportingOff = !source.isReportingEnabled
        self.now = now
        self.refreshTimeout = refreshTimeout
    }

    // MARK: Loading (R12)

    /// Reads once, then reloads after every change the source reports. Returns when the
    /// change stream ends or the task is cancelled.
    public func start() async {
        let changes = source.changes()  // subscribe first so no change is missed
        await reload()
        for await _ in changes {
            if Task.isCancelled { break }
            await reload()
        }
    }

    /// Reads the snapshot and rebuilds rows and state.
    public func reload() async {
        do {
            let file = try await source.current()
            snapshot = file
            loadError = nil
        } catch {
            loadError = Self.message(error)
        }
        rebuild()
    }

    /// User refresh (pull, button, ⌘R): `.userRefresh` (lead's call 13), with spinner. Never throws.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await runRefresh(userInitiated: true)
    }

    /// Foreground or popover open: `.foreground`, no spinner.
    public func refreshOnForeground() async {
        await runRefresh(userInitiated: false)
    }

    private func runRefresh(userInitiated: Bool) async {
        let source = self.source
        let timeout = refreshTimeout
        let outcome: String?? = await withTaskGroup(of: String??.self) { group in
            group.addTask {
                do { try await source.requestRefresh(userInitiated: userInitiated); return .some(nil) }
                catch { return .some(Self.message(error)) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .none  // timed out
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
        switch outcome {
        case .some(nil): refreshError = nil
        case .some(let message?): refreshError = message
        case .none: refreshError = "Timed out"
        }
        await reload()
    }

    // MARK: Actions

    /// Rename is offered for this device's row only, and only once its ID is known (R3, edge cases).
    public func canRename(_ row: DeviceRowModel) -> Bool { row.isThisDevice && thisDeviceID != nil }

    /// R3: trims; `nil` or blank resets to the default name. The row shows the new name once
    /// the record carries it.
    public func renameThisDevice(to name: String?) async {
        guard thisDeviceID != nil else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        await source.setThisDeviceName(trimmed?.isEmpty == false ? trimmed : nil)
        preferences = preferencesStore.load()
        await reload()
    }

    /// Hides or unhides a row (R2), local to this device. A grouped row is hidden by its group ID.
    public func setHidden(_ id: DeviceID, _ hidden: Bool) {
        var p = preferencesStore.load()  // fresh copy: the source may have saved a rename
        if hidden { p.hidden.insert(id) } else { p.hidden.remove(id) }
        preferencesStore.save(p)
        preferences = p
        rebuild()
        let source = self.source
        Task { await source.displayPreferencesChanged() }  // widgets hide it too (SYNC-001 R8a)
    }

    /// Removes a device and its accessories, or every record of a grouped row (UI-002 R11,
    /// SYNC-001 R15). This device can't be removed; the call does nothing for it.
    public func remove(_ id: DeviceID) async throws {
        guard id != thisDeviceID else { return }
        let row = (rows + oldRows + hiddenRows).first { $0.id == id }
        for member in row?.memberIDs ?? [id] { try await source.remove(member) }
        await reload()
    }

    /// UI-002 R12 → SYNC-001 R15a. On error nothing changes and the error is thrown.
    public func removeAllData() async throws {
        try await source.removeAllData()
        isReportingOff = true
        await reload()
    }

    /// UI-002 R12 → SYNC-001 R15a.
    public func resumeReporting() async {
        await source.resumeReporting()
        isReportingOff = false
        await reload()
    }

    /// Hides the "Couldn't update" banner until a different error comes.
    public func dismissSyncError() {
        if case .syncError(let message) = state { dismissedError = message }
        rebuild()
    }

    // MARK: Derivation

    private func rebuild() {
        let file = snapshot ?? SnapshotFile()
        thisDeviceID = file.ownDeviceID
        let built = DeviceRows(devices: file.devices, thisDeviceID: file.ownDeviceID,
                               preferences: preferences, now: now())
        rows = built.rows
        oldRows = built.oldRows
        hiddenRows = built.hiddenRows
        state = Self.state(snapshot: snapshot, rows: rows, error: loadError ?? refreshError, dismissed: dismissedError,
                           isHubMode: isHubMode)
    }

    /// `.signedOut` / `.restricted` → `.noICloud`; a read, refresh or fetch error → `.syncError`
    /// (unless dismissed); else by rows. `.loading` only before the first successful read.
    static func state(snapshot: SnapshotFile?, rows: [DeviceRowModel], error: String?, dismissed: String?,
                      isHubMode: Bool = false) -> State {
        if isHubMode, let hub = hubState(snapshot?.syncStatus) { return hub }
        if let status = snapshot?.syncStatus, status == .signedOut || status == .restricted { return .noICloud }
        if let message = error ?? snapshot.flatMap(cachedError), message != dismissed { return .syncError(message) }
        if snapshot == nil { return error == nil ? .loading : .empty }
        if rows.isEmpty { return .empty }
        if rows.count == 1, rows[0].isThisDevice { return .onlyThisDevice }
        return .loaded
    }

    /// NET-004 R11: hub statuses → `.notPaired` or a hub banner; `nil` for the others.
    /// iCloud states never show in hub mode.
    static func hubState(_ status: SyncStatus?) -> State? {
        switch status {
        case .notPaired?: .notPaired
        case .awayFromHub(let at)?: .hub(.away(lastContactAt: at))
        case .restricted?: .hub(.localNetworkOff)
        case .misconfigured(401)?: .hub(.forgotThisPhone)
        case .misconfigured(426)?: .hub(.updateNeeded)
        default: nil
        }
    }

    /// An error the cache records: sync offline, misconfigured, iCloud full, or a failed fetch.
    static func cachedError(_ file: SnapshotFile) -> String? {
        switch file.syncStatus {
        case .offline?: return "Offline"
        case .notPaired?, .awayFromHub?: break  // hub states (NET-004 R11), not errors
        case .misconfigured(let code)?: return "Misconfigured (\(code))"
        case .iCloudFull?: return "iCloud full"
        default: break
        }
        if case .failed(let reason)? = file.lastFetchOutcome { return reason }
        return nil
    }

    nonisolated static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
