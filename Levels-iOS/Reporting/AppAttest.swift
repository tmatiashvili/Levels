// Push (ADR-0023, PUSH-001 R31, R34, R71): App Attest for the relay's grants. Compiled only with
// LEVELS_PUSH_ENABLED = YES (Config/Levels.xcconfig); then the app signs with
// Config/Levels-iOS-Push.entitlements, which holds the App Attest environment. The free
// Personal Team build has neither this file nor the entitlement.
#if LEVELS_PUSH
import DeviceCheck
import Foundation
import LevelsModel
import LevelsNet

/// `DCAppAttestService.shared`. Only the app uses it; the widget extension can't (Apple:
/// most extensions can't generate App Attest keys).
struct DeviceCheckAppAttest: AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

enum PushRegistrationFactory {
    /// The iPhone's push registration, or `nil` (push off) when no relay URL is configured.
    static func make(appGroupID: String?) -> (any PushRegistrationSource)? {
        guard let relay = PushGrantRelayClient(relayURL: LevelsAppConfig.pushRelayURL ?? "") else { return nil }
        let service = LevelsAppConfig.keychainService.replacingOccurrences(of: ".device-identity", with: "") + ".push"
        return RelayPushGrantProvider(relay: relay, attest: DeviceCheckAppAttest(),
                                      items: SecKeychainItems(accessGroup: nil),  // the app's own group; the widget never reads it
                                      service: service,
                                      tokens: { await PushTokenSource.current(appGroupID: appGroupID) })
    }
}
#endif
