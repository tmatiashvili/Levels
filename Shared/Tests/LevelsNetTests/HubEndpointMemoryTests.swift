import Foundation
import Network
import Testing
@testable import LevelsNet

/// The Mac's last address, kept so the widget can skip Bonjour (2026-11-24: widget fetches that
/// did not fit in 4 s).
@Suite("Hub endpoint memory")
struct HubEndpointMemoryTests {
    let hub = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!
    let t = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func keepsPlainAddressesOnly() throws {
        let v4 = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 51234)
        let r = try #require(HubEndpointRecord(endpoint: v4, hubID: hub, savedAt: t))
        #expect(r.host == "192.168.1.20" && r.port == 51234)
        #expect(r.endpoint == v4)

        let v6 = NWEndpoint.hostPort(host: .ipv6(IPv6Address("2001:db8::5")!), port: 8443)
        #expect(HubEndpointRecord(endpoint: v6, hubID: hub, savedAt: t)?.endpoint == v6)

        // Not worth keeping: a Bonjour service, a name, link-local IPv6 without its interface.
        #expect(HubEndpointRecord(endpoint: .service(name: "Levels-ab", type: "_levels._tcp", domain: "local.", interface: nil),
                                  hubID: hub, savedAt: t) == nil)
        #expect(HubEndpointRecord(endpoint: .hostPort(host: .name("mac.local", nil), port: 1), hubID: hub, savedAt: t) == nil)
        #expect(HubEndpointRecord(endpoint: .hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: 1), hubID: hub, savedAt: t) == nil)
    }

    @Test func usableOnlyForTheSameHubAndWhileRecent() {
        let r = HubEndpointRecord(hubID: hub, host: "10.0.0.2", port: 4000, savedAt: t)
        #expect(r.isUsable(for: hub, now: t + 3600))
        #expect(!r.isUsable(for: UUID(), now: t + 3600))  // another Mac paired since
        #expect(!r.isUsable(for: hub, now: t + HubEndpointRecord.maxAge))
        #expect(!r.isUsable(for: hub, now: t - 3600))  // clock moved back a lot
        #expect(!HubEndpointRecord(hubID: hub, host: "not an address", port: 4000, savedAt: t).isUsable(for: hub, now: t))
        #expect(!HubEndpointRecord(hubID: hub, host: "10.0.0.2", port: 0, savedAt: t).isUsable(for: hub, now: t))
    }

    @Test func userDefaultsRoundTrip() {
        let suite = "levels.tests.endpoint.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let memory = UserDefaultsHubEndpointMemory(suiteName: suite)
        #expect(memory.load() == nil)
        let r = HubEndpointRecord(hubID: hub, host: "10.0.0.2", port: 4000, savedAt: t)
        memory.save(r)
        #expect(memory.load() == r)
        memory.clear()
        #expect(memory.load() == nil)
    }
}
