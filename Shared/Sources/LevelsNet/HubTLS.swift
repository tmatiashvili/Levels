import CryptoKit
import Foundation
import Network
import Security

/// TLS 1.2 with pre-shared keys (NET-001 R5, ADR-0020 Decision 4).
///
/// NET-001 AC1 spike (2026-11-24, macOS 26 loopback): the server holds one PSK per
/// identity (`sec_protocol_options_add_pre_shared_key` called once per paired device) and
/// TLS picks the one the client names. The selection block runs on the server with the
/// client's identity as its `psk_identity_hint` argument; completing with `nil` refuses the
/// handshake, so a removed device or a closed pairing window is refused at once. Keys added
/// to the options after the listener started are not seen, so the Mac rebuilds the
/// listener on the same port whenever the key set changes (open connections survive).
/// Wrong key: server `-9846 bad MAC`, client `-9820`; unknown identity: `-9864` both sides.
public enum HubTLS {
    /// `TLS_PSK_WITH_AES_128_GCM_SHA256`, TLS 1.2 only, no session resumption.
    static func base() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        // A resumed session skips the PSK selection block, so the server would not learn
        // the caller's identity (seen in the loopback tests). Every connection does a full handshake.
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        return options
    }

    static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    static func add(_ options: NWProtocolTLS.Options, identity: String, key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions,
                                                dispatchData(keyData) as __DispatchData,
                                                dispatchData(Data(identity.utf8)) as __DispatchData)
    }

    /// Client side: one identity and key.
    public static func clientOptions(identity: String, key: SymmetricKey) -> NWProtocolTLS.Options {
        let options = base()
        add(options, identity: identity, key: key)
        return options
    }

    /// Server side: every identity the listener accepts with its key. `select` runs per
    /// handshake on `queue` with the client's identity and the handshake's metadata (the
    /// same object the ready connection reports); returning `false` refuses the handshake.
    public static func serverOptions(keys: [String: SymmetricKey], queue: DispatchQueue,
                                     select: @escaping @Sendable (String, sec_protocol_metadata_t) -> Bool) -> NWProtocolTLS.Options {
        let options = base()
        for (identity, key) in keys.sorted(by: { $0.key < $1.key }) {
            add(options, identity: identity, key: key)
        }
        sec_protocol_options_set_pre_shared_key_selection_block(options.securityProtocolOptions, { metadata, hint, complete in
            guard let hint else { complete(nil); return }
            let identity = String(decoding: Data(hint as DispatchData), as: UTF8.self)
            complete(select(identity, metadata) ? hint : nil)
        }, queue)
        return options
    }
}
