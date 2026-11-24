// NET-001 AC1 spike (2026-11-24). Run: swiftc psk.swift -o /tmp/psk && /tmp/psk multi|sel|late
// Loopback only; the permanent checks are LevelsNetTests/TLSLoopbackTests and LevelsSyncTests/HubLoopbackTests.
import Foundation
import Network
import Security

func dd(_ s: String) -> DispatchData { s.data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) } }
func dd(_ d: Data) -> DispatchData { d.withUnsafeBytes { DispatchData(bytes: $0) } }

let q = DispatchQueue(label: "spike")
let mode = CommandLine.arguments.dropFirst().first ?? "multi"

func tls(psks: [(String, Data)], useSelection: Bool = false) -> NWProtocolTLS.Options {
    let o = NWProtocolTLS.Options()
    let s = o.securityProtocolOptions
    for (id, key) in psks {
        sec_protocol_options_add_pre_shared_key(s, dd(key) as __DispatchData, dd(id) as __DispatchData)
    }
    sec_protocol_options_append_tls_ciphersuite(s, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    sec_protocol_options_set_min_tls_protocol_version(s, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(s, .TLSv12)
    if useSelection {
        sec_protocol_options_set_pre_shared_key_selection_block(s, { meta, hint, complete in
            print("selection meta id:", ObjectIdentifier(meta as AnyObject), "hint:", hint.map { String(decoding: Data($0 as DispatchData), as: UTF8.self) } ?? "nil")
            if let hint, String(decoding: Data(hint as DispatchData), as: UTF8.self) != "dev-b" { complete(hint) } else { complete(nil) }
        }, q)
    }
    return o
}

let keyA = Data(repeating: 0xA1, count: 32), keyB = Data(repeating: 0xB2, count: 32)
let serverPSKs = [("dev-a", keyA), ("dev-b", keyB)]
let serverTLS = tls(psks: serverPSKs, useSelection: mode == "sel")
let lateOpts: NWProtocolTLS.Options? = serverTLS
let params = NWParameters(tls: serverTLS, tcp: .init())
let listener = try! NWListener(using: params, on: .any)
let sem = DispatchSemaphore(value: 0)
listener.newConnectionHandler = { c in
    c.stateUpdateHandler = { st in
        print("  server conn:", st)
        if case .ready = st {
            if let m = c.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                // peer identity
                print("  ready meta id:", ObjectIdentifier(m.securityProtocolMetadata as AnyObject))
                sec_protocol_metadata_access_pre_shared_keys(m.securityProtocolMetadata) { _, ident in print("  access psk identity:", String(decoding: Data(ident as DispatchData), as: UTF8.self)) }
                print("  server negotiated suite:", sec_protocol_metadata_get_negotiated_tls_ciphersuite(m.securityProtocolMetadata).rawValue)
            }
            c.receive(minimumIncompleteLength: 1, maximumLength: 100) { d, _, _, _ in
                print("  server got:", d.map { String(decoding: $0, as: UTF8.self) } ?? "nil"); c.send(content: Data("pong".utf8), completion: .contentProcessed { _ in }) }
        }
    }
    c.start(queue: q)
}
listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
listener.start(queue: q); sem.wait()
let port = listener.port!
if mode == "late" {
    // add dev-c key to the live options object after start
    lateOpts.map { sec_protocol_options_add_pre_shared_key($0.securityProtocolOptions, dd(Data(repeating: 0xC3, count: 32)) as __DispatchData, dd("dev-c") as __DispatchData) }
}

func attempt(_ name: String, id: String, key: Data) {
    let done = DispatchSemaphore(value: 0)
    let c = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: tls(psks: [(id, key)]), tcp: .init()))
    var finished = false
    c.stateUpdateHandler = { st in
        print(" client \(name):", st)
        switch st {
        case .ready:
            c.send(content: Data("ping".utf8), completion: .contentProcessed { _ in })
            c.receive(minimumIncompleteLength: 1, maximumLength: 100) { d, _, _, e in
                print(" client \(name) got:", d.map { String(decoding: $0, as: UTF8.self) } ?? "nil", e as Any)
                if !finished { finished = true; c.cancel(); done.signal() } }
        case .failed, .waiting:
            if !finished { finished = true; c.cancel(); done.signal() }
        default: break
        }
    }
    c.start(queue: q)
    _ = done.wait(timeout: .now() + 5)
    print("---")
}
attempt("A right", id: "dev-a", key: keyA)
attempt("B right", id: "dev-b", key: keyB)
attempt("B with A key", id: "dev-b", key: keyA)
attempt("unknown id", id: "dev-x", key: keyA)
attempt("late C", id: "dev-c", key: Data(repeating: 0xC3, count: 32))
Thread.sleep(forTimeInterval: 0.5)
