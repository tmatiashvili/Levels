// NET-001 AC1 spike (2026-11-24). Run: swiftc restart.swift -o /tmp/restart && /tmp/restart
// Loopback only; the permanent checks are LevelsNetTests/TLSLoopbackTests and LevelsSyncTests/HubLoopbackTests.
import Foundation
import Network
import Security
func dd(_ d: Data) -> DispatchData { d.withUnsafeBytes { DispatchData(bytes: $0) } }
let q = DispatchQueue(label: "s")
func tls(_ psks: [(String, Data)]) -> NWProtocolTLS.Options {
    let o = NWProtocolTLS.Options(); let s = o.securityProtocolOptions
    for (id, k) in psks { sec_protocol_options_add_pre_shared_key(s, dd(k) as __DispatchData, dd(Data(id.utf8)) as __DispatchData) }
    sec_protocol_options_append_tls_ciphersuite(s, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_min_tls_protocol_version(s, .TLSv12); sec_protocol_options_set_max_tls_protocol_version(s, .TLSv12)
    return o
}
var conns: [NWConnection] = []
func makeListener(_ psks: [(String, Data)], port: NWEndpoint.Port) -> NWListener {
    let p = NWParameters(tls: tls(psks), tcp: .init()); p.allowLocalEndpointReuse = true
    let l = try! NWListener(using: p, on: port)
    l.newConnectionHandler = { c in conns.append(c); c.stateUpdateHandler = { if case .ready = $0 { echo(c) } }; c.start(queue: q) }
    let sem = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { st in print("listener", st); if case .ready = st { sem.signal() }; if case .failed = st { sem.signal() } }
    l.start(queue: q); sem.wait(); return l
}
func echo(_ c: NWConnection) { c.receive(minimumIncompleteLength: 1, maximumLength: 100) { d, _, done, e in if let d { c.send(content: d, completion: .contentProcessed { _ in }) }; if e == nil && !done { echo(c) } } }
func client(_ id: String, _ k: Data, _ port: NWEndpoint.Port) -> NWConnection? {
    let c = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: tls([(id, k)]), tcp: .init()))
    let sem = DispatchSemaphore(value: 0); var ok = false
    c.stateUpdateHandler = { st in if case .ready = st { ok = true; sem.signal() }; if case .waiting = st { sem.signal() }; if case .failed = st { sem.signal() } }
    c.start(queue: q); _ = sem.wait(timeout: .now() + 3); return ok ? c : nil
}
func ping(_ c: NWConnection) -> Bool {
    let sem = DispatchSemaphore(value: 0); var ok = false
    c.send(content: Data("hi".utf8), completion: .contentProcessed { _ in })
    c.receive(minimumIncompleteLength: 1, maximumLength: 10) { d, _, _, _ in ok = d != nil; sem.signal() }
    _ = sem.wait(timeout: .now() + 2); return ok
}
let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
let l1 = makeListener([("a", a)], port: .any); let port = l1.port!
let ca = client("a", a, port)!; print("a ping before restart:", ping(ca))
print("b before restart:", client("b", b, port) != nil)
l1.cancel(); Thread.sleep(forTimeInterval: 0.05)
let l2 = makeListener([("a", a), ("b", b)], port: port); print("same port:", l2.port == port)
print("a ping after restart (old conn):", ping(ca))
print("b after restart:", client("b", b, port) != nil)
