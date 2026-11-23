// MAC-001 R4(a)(b), R6: open at login through SMAppService, behind a protocol so the rules
// can be faked.
import Foundation
import Observation
import ServiceManagement
import LevelsModel
import os

/// The parts of `SMAppService.mainApp` the controller uses.
protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

struct MainAppLoginService: LoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor @Observable final class LoginItemController {
    /// R6: set after the one automatic registration.
    static let didOfferKey = "didOfferLoginItem"
    private static let logger = Logger(subsystem: LevelsLog.subsystem, category: "app")

    private(set) var status: SMAppService.Status
    private(set) var lastError: String?
    @ObservationIgnored private let service: any LoginService
    @ObservationIgnored private let defaults: UserDefaults

    init(service: any LoginService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        status = service.status
    }

    /// R4(a): on only for `.enabled`.
    var isEnabled: Bool { status == .enabled }
    /// R4(b).
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() { status = service.status }

    /// R4(a): only this toggle calls register / unregister after the first launch.
    func setEnabled(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("Login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// R6: on the very first launch register once; never again by itself.
    func registerOnFirstLaunchIfNeeded() {
        guard !defaults.bool(forKey: Self.didOfferKey) else { return }
        defaults.set(true, forKey: Self.didOfferKey)
        setEnabled(true)
        Self.logger.notice("First launch: login item status \(String(describing: self.status), privacy: .public)")
    }

    func openLoginItemsSettings() { service.openSystemSettingsLoginItems() }
}
