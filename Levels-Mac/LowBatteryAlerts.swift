// ALR-001 on the Mac: runs the shared LowBatteryAlertRule on every snapshot change and posts
// local notifications through UNUserNotificationCenter. No entitlement needed (unsandboxed agent,
// lead's call 16). Permission is asked when first needed, never at launch (lead's call 18b).
import AppKit
import Foundation
import LevelsModel
import LevelsUI
import Observation
import SwiftUI
import UserNotifications
import os

@MainActor @Observable final class AlertController {
    enum Authorization: Equatable { case notDetermined, allowed, denied }

    nonisolated static let logger = Logger(subsystem: LevelsLog.subsystem, category: "alerts")

    private(set) var settings: AlertSettings
    private(set) var authorization: Authorization = .notDetermined

    @ObservationIgnored private let store: any AlertStore
    @ObservationIgnored private let source: any DeviceSnapshotSource
    @ObservationIgnored private let preferences: any DisplayPreferencesStore
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let delegate = NotificationDelegate()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: any AlertStore, source: any DeviceSnapshotSource, preferences: any DisplayPreferencesStore) {
        self.store = store
        self.source = source
        self.preferences = preferences
        settings = store.loadSettings(defaults: .defaults(for: .mac))  // R1, owner decision H
        center.delegate = delegate  // before launch finishes, so a tap that launches the app arrives (R9)
    }

    /// R12: evaluates now and on every snapshot change. Runs once.
    func start() {
        guard task == nil else { return }
        let changes = source.changes()
        task = Task {
            await refreshAuthorization()
            await evaluate()
            for await _ in changes { await evaluate() }
        }
    }

    // MARK: Settings (R1, R4, R7, R10)

    /// Turning alerts on asks for permission if macOS hasn't been asked yet (R10).
    func setEnabled(_ on: Bool) {
        settings.isEnabled = on
        store.saveSettings(settings)
        Self.logger.notice("Alerts \(on ? "on" : "off", privacy: .public)")
        guard on else { return }
        Task {
            await requestAuthorizationIfNeeded()
            await evaluate()
        }
    }

    func setThreshold(_ threshold: Int) {
        settings.threshold = threshold
        store.saveSettings(settings)
        Task { await evaluate() }
    }

    func isMuted(_ id: DeviceID) -> Bool { settings.mutedDevices.contains(id) }

    func setMuted(_ id: DeviceID, _ muted: Bool) {
        if muted { settings.mutedDevices.insert(id) } else { settings.mutedDevices.remove(id) }
        store.saveSettings(settings)
        Task { await evaluate() }
    }

    /// Re-read when Settings appears (R10).
    func refreshAuthorization() async {
        let status = await center.notificationSettings().authorizationStatus
        authorization = switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed  // authorized, provisional, ephemeral
        }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Evaluation

    /// R2–R7, R11. State is loaded and saved with no suspension in between, so overlapping
    /// evaluations on the main actor can't both alert for one subject.
    func evaluate() async {
        guard let snapshot = try? await source.current() else { return }
        let now = Date()
        let subjects = LowBatteryAlertRule.subjects(in: snapshot, hidden: preferences.load().hidden, now: now)
        if !source.isReportingEnabled { forgetDevices() }  // R11
        let result = LowBatteryAlertRule.evaluate(subjects, settings: settings, state: store.loadState(),
                                                  reportingEnabled: source.isReportingEnabled, now: now)
        store.saveState(result.state)
        for alert in result.alerts { await post(alert) }
    }

    /// R11 (ADR-0019): after Remove all my data no device names stay behind in Notification
    /// Center or in the per-device switches.
    private func forgetDevices() {
        center.removeAllDeliveredNotifications()
        guard !settings.mutedDevices.isEmpty else { return }
        settings.forgetDevices()
        store.saveSettings(settings)
        Self.logger.notice("Reporting off: cleared delivered alerts and per-device switches")
    }

    private func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Self.logger.notice("Notification permission \(granted ? "granted" : "not granted", privacy: .public)")
        } catch {
            Self.logger.error("Notification permission request failed: \(String(describing: error), privacy: .public)")
        }
        await refreshAuthorization()
    }

    /// R8, R10: asks first if macOS hasn't been asked; posts nothing when denied.
    private func post(_ alert: LowBatteryAlert) async {
        await requestAuthorizationIfNeeded()
        guard authorization == .allowed else {
            Self.logger.notice("Alert \(alert.identifier, privacy: .public) not posted: notifications not allowed")
            return
        }
        let content = UNMutableNotificationContent()
        content.body = alert.text
        content.sound = .default
        content.threadIdentifier = "low-battery"
        content.userInfo = ["url": alert.url.absoluteString]
        do {
            try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
            Self.logger.notice("Posted \(alert.identifier, privacy: .public) level=\(alert.level)")
        } catch {
            Self.logger.error("Posting \(alert.identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Shows banners while the agent is active and opens the device on tap (R9).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: raw) else { return }
        AlertController.logger.notice("Notification tapped: \(raw, privacy: .public)")
        // Sent to this app's own bundle, so another copy that also handles levels:// never gets it.
        await MainActor.run {
            NSWorkspace.shared.open([url], withApplicationAt: Bundle.main.bundleURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// ALR-001 Settings section: master switch, threshold, per-device switches, permission and
/// reporting notes (R1, R4, R7, R10, R11).
struct AlertsSettingsSection: View {
    let alerts: AlertController
    let store: DeviceListStore

    var body: some View {
        Section("Alerts") {
            Toggle("Low-battery alerts", isOn: Binding(get: { alerts.settings.isEnabled },
                                                       set: { alerts.setEnabled($0) }))
            Picker("Alert at", selection: Binding(get: { alerts.settings.threshold },
                                                  set: { alerts.setThreshold($0) })) {
                ForEach(Array(stride(from: AlertSettings.thresholdRange.lowerBound,
                                     through: AlertSettings.thresholdRange.upperBound,
                                     by: AlertSettings.thresholdStep)), id: \.self) { Text("\($0)%").tag($0) }
            }
            .disabled(!alerts.settings.isEnabled)
            if alerts.settings.isEnabled && alerts.authorization == .denied {
                HStack {
                    Text("Notifications for Levels are off in System Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Notification Settings") { alerts.openNotificationSettings() }
                }
            }
            if store.isReportingOff {
                Text("Alerts pause while reporting is off.").font(.callout).foregroundStyle(.secondary)
            }
            let devices = store.rows.filter { !$0.isThisDevice && $0.hasBattery }
            ForEach(devices) { row in
                Toggle(row.name, isOn: Binding(get: { !alerts.isMuted(row.id) },
                                               set: { alerts.setMuted(row.id, !$0) }))
                    .disabled(!alerts.settings.isEnabled)
            }
            Text("Levels alerts once when an accessory drops to this level, and again after it has been charged. macOS warns about this Mac's own battery.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await alerts.refreshAuthorization() }
    }
}
