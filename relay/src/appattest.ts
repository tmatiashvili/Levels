// App Attest verification for the iPhone app (PUSH-001 R30–R36), following
// Apple's "Validating apps that connect to your server". The relay verifies
// one attestation per App Attest key and then trusts assertions signed by
// that key. It is stateless: the assertion counter is not tracked; replays are
// bounded by the 5-minute single-purpose challenge instead (ADR-0023 T6).

import "reflect-metadata"; // @peculiar/x509 uses tsyringe, which needs it loaded first.
import * as x509 from "@peculiar/x509";
import { decodeCbor, decodeCborPrefix, type CborValue } from "./cbor.js";
import { concat, equalBytes, fromBase64, sha256, utf8 } from "./bytes.js";
import type { ApnsEnvironment } from "./apns.js";

x509.cryptoProvider.set(crypto);

/** Apple App Attestation Root CA, https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
 *  SHA-256 fingerprint 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32 */
export const APPLE_APP_ATTEST_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

export const NONCE_EXTENSION_OID = "1.2.840.113635.100.8.2";
const AAGUID_DEVELOPMENT = utf8.encode("appattestdevelop");
const AAGUID_PRODUCTION = concat(utf8.encode("appattest"), new Uint8Array(7));
/** Validation categories accepted for the iOS app: TestFlight, development, App Store. */
const ACCEPTED_VALIDATION_CATEGORIES = new Set([2, 3, 4]);

export class AttestError extends Error {
  constructor(public readonly code: string) {
    super(code);
  }
}

export interface AuthData {
  rpIdHash: Uint8Array;
  flags: number;
  counter: number;
  aaguid?: Uint8Array;
  credentialId?: Uint8Array;
  extensions?: Map<CborValue, CborValue>;
}

export function parseAuthData(b: Uint8Array): AuthData {
  if (b.length < 37) throw new AttestError("authdata_short");
  const rpIdHash = b.slice(0, 32);
  const flags = b[32]!;
  const counter = ((b[33]! << 24) >>> 0) + (b[34]! << 16) + (b[35]! << 8) + b[36]!;
  const out: AuthData = { rpIdHash, flags, counter };
  let pos = 37;
  if (flags & 0x40) {
    if (b.length < pos + 18) throw new AttestError("authdata_short");
    out.aaguid = b.slice(pos, pos + 16);
    const len = (b[pos + 16]! << 8) | b[pos + 17]!;
    pos += 18;
    if (b.length < pos + len) throw new AttestError("authdata_short");
    out.credentialId = b.slice(pos, pos + len);
    pos += len;
    try {
      pos += decodeCborPrefix(b.slice(pos)).length; // COSE public key; we use the certificate's key.
    } catch {
      throw new AttestError("authdata_cose");
    }
  }
  if (flags & 0x80) {
    let ext: CborValue;
    try {
      const d = decodeCborPrefix(b.slice(pos));
      ext = d.value;
      pos += d.length;
    } catch {
      throw new AttestError("authdata_extensions");
    }
    if (!(ext instanceof Map)) throw new AttestError("authdata_extensions");
    out.extensions = ext;
  }
  if (pos !== b.length) throw new AttestError("authdata_trailing");
  return out;
}

/** Extracts the single OCTET STRING inside the DER value of the nonce extension. */
export function findOctetString(der: Uint8Array): Uint8Array | undefined {
  let pos = 0;
  while (pos < der.length) {
    const tag = der[pos]!;
    let len = der[pos + 1];
    if (len === undefined) return undefined;
    let hdr = 2;
    if (len & 0x80) {
      const n = len & 0x7f;
      if (n < 1 || n > 3) return undefined;
      len = 0;
      for (let i = 0; i < n; i++) len = (len << 8) | (der[pos + 2 + i] ?? 0);
      hdr += n;
    }
    const start = pos + hdr;
    const end = start + len;
    if (end > der.length) return undefined;
    if (tag === 0x04) return der.slice(start, end);
    if (tag & 0x20) {
      const inner = findOctetString(der.slice(start, end));
      if (inner) return inner;
    }
    pos = end;
  }
  return undefined;
}

function environmentOf(aaguid: Uint8Array | undefined): ApnsEnvironment {
  if (aaguid && equalBytes(aaguid, AAGUID_PRODUCTION)) return "production";
  if (aaguid && equalBytes(aaguid, AAGUID_DEVELOPMENT)) return "development";
  throw new AttestError("aaguid");
}

function checkExtensions(ext: Map<CborValue, CborValue> | undefined): void {
  // Apple added apple_validation_category_01 and apple_bundle_version_01.
  // **Assumption (ADR-0023):** older iOS 26 builds may omit the extensions
  // dictionary; then we accept. When present, the category must be one we ship.
  if (!ext) return;
  const category = ext.get("apple_validation_category_01");
  if (category !== undefined && !(typeof category === "number" && ACCEPTED_VALIDATION_CATEGORIES.has(category))) {
    throw new AttestError("validation_category");
  }
}

export interface AttestationResult {
  publicKeyRaw: Uint8Array; // 65 bytes, X9.62 uncompressed
  env: ApnsEnvironment;
}

export interface AttestationInput {
  keyId: string; // base64, as returned by DCAppAttestService.generateKey
  attestation: Uint8Array;
  challenge: string; // the exact challenge string the relay issued
  appId: string; // "<TEAMID>.<bundle id>"
  now: Date;
  rootPem?: string; // tests inject their own root
}

export async function verifyAttestation(input: AttestationInput): Promise<AttestationResult> {
  let obj: CborValue;
  try {
    obj = decodeCbor(input.attestation);
  } catch {
    throw new AttestError("cbor");
  }
  if (!(obj instanceof Map) || obj.get("fmt") !== "apple-appattest") throw new AttestError("format");
  const attStmt = obj.get("attStmt");
  const authDataBytes = obj.get("authData");
  if (!(attStmt instanceof Map) || !(authDataBytes instanceof Uint8Array)) throw new AttestError("format");
  const x5c = attStmt.get("x5c");
  if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every((c) => c instanceof Uint8Array)) {
    throw new AttestError("x5c");
  }

  // 1. Chain: credCert <- intermediate <- Apple App Attestation Root CA.
  let leaf: x509.X509Certificate;
  let intermediate: x509.X509Certificate;
  let root: x509.X509Certificate;
  try {
    leaf = new x509.X509Certificate(x5c[0] as Uint8Array);
    intermediate = new x509.X509Certificate(x5c[1] as Uint8Array);
    root = new x509.X509Certificate(input.rootPem ?? APPLE_APP_ATTEST_ROOT_PEM);
  } catch {
    throw new AttestError("x5c");
  }
  const chainOk =
    (await intermediate.verify({ publicKey: root.publicKey, date: input.now }).catch(() => false)) &&
    (await leaf.verify({ publicKey: intermediate.publicKey, date: input.now }).catch(() => false));
  if (!chainOk) throw new AttestError("chain");

  // 2–3. nonce = SHA256(authData || SHA256(challenge)).
  const clientDataHash = await sha256(input.challenge);
  const nonce = await sha256(concat(authDataBytes, clientDataHash));

  // 4. The nonce extension must hold exactly that nonce.
  const ext = leaf.getExtension(NONCE_EXTENSION_OID);
  const certNonce = ext ? findOctetString(new Uint8Array(ext.value)) : undefined;
  if (!certNonce || !equalBytes(certNonce, nonce)) throw new AttestError("nonce");

  // 5. SHA256(public key) must equal the key identifier.
  let publicKeyRaw: Uint8Array;
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      leaf.publicKey.rawData,
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["verify"],
    );
    publicKeyRaw = new Uint8Array((await crypto.subtle.exportKey("raw", key)) as ArrayBuffer);
  } catch {
    throw new AttestError("public_key");
  }
  let keyIdBytes: Uint8Array;
  try {
    keyIdBytes = fromBase64(input.keyId);
  } catch {
    throw new AttestError("key_id");
  }
  if (!equalBytes(await sha256(publicKeyRaw), keyIdBytes)) throw new AttestError("key_id");

  // 6–9. RP ID, counter, aaguid, credential ID.
  const auth = parseAuthData(authDataBytes);
  if (!equalBytes(auth.rpIdHash, await sha256(input.appId))) throw new AttestError("rp_id");
  if (auth.counter !== 0) throw new AttestError("counter");
  const env = environmentOf(auth.aaguid);
  if (!auth.credentialId || !equalBytes(auth.credentialId, keyIdBytes)) throw new AttestError("credential_id");
  checkExtensions(auth.extensions);

  return { publicKeyRaw, env };
}

export interface AssertionInput {
  assertion: Uint8Array;
  clientData: Uint8Array; // exact bytes the app hashed
  publicKeyRaw: Uint8Array;
  appId: string;
}

/** Verifies an assertion's signature and RP ID. Returns the counter. */
export async function verifyAssertion(input: AssertionInput): Promise<number> {
  let obj: CborValue;
  try {
    obj = decodeCbor(input.assertion);
  } catch {
    throw new AttestError("cbor");
  }
  if (!(obj instanceof Map)) throw new AttestError("format");
  const signature = obj.get("signature");
  const authenticatorData = obj.get("authenticatorData");
  if (!(signature instanceof Uint8Array) || !(authenticatorData instanceof Uint8Array)) {
    throw new AttestError("format");
  }
  const nonce = await sha256(concat(authenticatorData, await sha256(input.clientData)));
  const key = await crypto.subtle.importKey(
    "raw",
    input.publicKeyRaw,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const raw = derToRawSignature(signature);
  // App Attest signs nonce with ECDSA-SHA256, so the verifier hashes nonce again.
  const ok = raw
    ? await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, nonce)
    : false;
  if (!ok) throw new AttestError("signature");
  const auth = parseAuthData(authenticatorData);
  if (!equalBytes(auth.rpIdHash, await sha256(input.appId))) throw new AttestError("rp_id");
  if (auth.counter <= 0) throw new AttestError("counter");
  checkExtensions(auth.extensions);
  return auth.counter;
}

/** Converts a DER ECDSA signature (SEQUENCE { r INTEGER, s INTEGER }) to raw r||s (64 bytes). */
export function derToRawSignature(der: Uint8Array): Uint8Array | undefined {
  if (der.length < 8 || der[0] !== 0x30) return undefined;
  let pos = 2;
  if (der[1]! & 0x80) pos = 2 + (der[1]! & 0x7f);
  const ints: Uint8Array[] = [];
  for (let i = 0; i < 2; i++) {
    if (der[pos] !== 0x02) return undefined;
    const len = der[pos + 1]!;
    let v = der.slice(pos + 2, pos + 2 + len);
    pos += 2 + len;
    while (v.length > 32 && v[0] === 0) v = v.slice(1);
    if (v.length > 32) return undefined;
    const padded = new Uint8Array(32);
    padded.set(v, 32 - v.length);
    ints.push(padded);
  }
  return concat(ints[0]!, ints[1]!);
}
