import Foundation
import LevelsModel

// Push-driven widget updates (owner decision 2026-11-24; ADR-0023 / PUSH-001 on
// feature/push-relay). The iPhone widget gets a WidgetKit push token, the app sends it to the
// paired Mac (`PUT /v1/push-tokens`), and the Mac asks the relay to push when what the widget
// shows changed. Everything here is inert until `LEVELS_PUSH_ENABLED = YES` (Config/Levels.xcconfig):
// a free Personal Team can't sign `aps-environment`, so no token ever exists in those builds.

/// The APNs environment a token belongs to. Raw values are the relay contract's `env`.
public enum APNsEnvironment: String, Codable, Sendable, Equatable {
    case development
    case production

    /// The `aps-environment` of the running build, from its embedded provisioning profile.
    /// Xcode (development) and ad-hoc builds embed one; TestFlight and App Store builds don't,
    /// and those are always `production`.
    public static func current(bundle: Bundle = .main) -> APNsEnvironment {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        return fromProvisioningProfile(try? Data(contentsOf: url))
    }

    /// Reads `Entitlements.aps-environment` from a `.mobileprovision` (a CMS envelope around
    /// an XML plist). No profile → `production`; a profile without the key → `development`
    /// (an Xcode build with push off, which never gets a token anyway). Pure; unit-tested.
    public static func fromProvisioningProfile(_ data: Data?) -> APNsEnvironment {
        guard let data else { return .production }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return .development }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String
        else { return .development }
        return value == "production" ? .production : .development
    }
}

/// What a token updates. Raw values are the relay contract's `kind`.
public enum PushTokenKind: String, Codable, Sendable, Equatable {
    case widget
    case liveActivity
}

/// One APNs token as the hub and the relay carry it.
public struct PushToken: Codable, Sendable, Equatable, Hashable {
    /// Lowercase hex.
    public var token: String
    public var env: APNsEnvironment
    public var kind: PushTokenKind

    public init(token: String, env: APNsEnvironment, kind: PushTokenKind) {
        self.token = token
        self.env = env
        self.kind = kind
    }

    public init(data: Data, env: APNsEnvironment, kind: PushTokenKind) {
        self.init(token: data.map { String(format: "%02x", $0) }.joined(), env: env, kind: kind)
    }

    /// Longest accepted token, in hex characters. APNs tokens are 32 bytes today; Apple says
    /// not to rely on that, so allow growth.
    public static let maxHexLength = 400

    /// Even-length lowercase hex, 16…``maxHexLength`` characters.
    public var isValid: Bool {
        (16...Self.maxHexLength).contains(token.count) && token.count.isMultiple(of: 2)
            && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// `PUT /v1/push-tokens` body: the device's full token set (replaces what the Mac holds).
/// An empty list clears it.
public struct PushTokenUpload: Codable, Sendable, Equatable {
    public var v: Int
    public var tokens: [PushToken]

    public init(v: Int = HubProtocol.pushTokensVersion, tokens: [PushToken]) {
        self.v = v
        self.tokens = tokens
    }
}

extension HubProtocol {
    /// Version of the `PUT /v1/push-tokens` body. The route is additive: the snapshot
    /// protocol stays at ``version``; an older Mac answers 404 and the iPhone stops asking.
    public static let pushTokensVersion = 1
    /// At most this many tokens per paired device (a widget token, a Live Activity token, spares).
    public static let maxPushTokensPerDevice = 4
}

// MARK: - Widget token in the App Group

/// The widget extension's push token, kept in App Group `UserDefaults` so the app can send it
/// to the Mac and the widget can tell push is on (``HubWidgetPlan`` fetches on every push
/// reload then).
public struct WidgetPushTokenStore: Sendable {
    public static let key = "push.widgetToken"
    private let suiteName: String?

    public init(suiteName: String?) { self.suiteName = suiteName }

    private var defaults: UserDefaults? { suiteName.flatMap(UserDefaults.init(suiteName:)) }

    public func load() -> PushToken? {
        guard let data = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PushToken.self, from: data)
    }

    /// Returns whether the stored token changed.
    @discardableResult
    public func save(_ token: PushToken) -> Bool {
        guard let defaults, load() != token, let data = try? JSONEncoder().encode(token) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    public func clear() { defaults?.removeObject(forKey: Self.key) }
}
