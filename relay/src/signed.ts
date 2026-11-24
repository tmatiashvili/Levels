// Stateless, relay-signed blobs (PUSH-001 R30–R38): challenges, device
// credentials and push grants. Format: "<prefix>.<base64url JSON>.<base64url HMAC>".
// The HMAC is HMAC-SHA256 with RELAY_HMAC_KEY over "<prefix>.<base64url JSON>".
// The relay stores nothing; rotating RELAY_HMAC_KEY revokes everything.

import {
  equalBytes,
  fromBase64Url,
  hmac,
  hmacKey,
  sha256,
  toBase64Url,
  utf8,
} from "./bytes.js";
import type { ApnsEnvironment, PushKind } from "./apns.js";

export const CHALLENGE_TTL_SECONDS = 5 * 60;
export const GRANT_TTL_SECONDS = 30 * 24 * 3600;
export const CREDENTIAL_TTL_SECONDS = 365 * 24 * 3600;
export const MAX_GRANT_TOKENS = 4;

export interface ChallengeBody {
  n: string; // 16 random bytes, base64url
  exp: number;
}

export interface CredentialBody {
  v: 1;
  /** App Attest key identifier (base64 of SHA-256 of the public key), as the app sends it. */
  kid: string;
  /** Attested P-256 public key, X9.62 uncompressed (65 bytes), base64url. */
  pk: string;
  env: ApnsEnvironment;
  iat: number;
  exp: number;
}

export interface GrantBody {
  v: 1;
  /** Environment the grant covers; equals the App Attest environment of the iPhone. */
  env: ApnsEnvironment;
  /** The Mac's P-256 signing public key, X9.62 uncompressed (65 bytes), base64url. */
  mac: string;
  /** Device ID for rate limiting: deviceIdFromKeyId(decoded App Attest key ID). */
  dev: string;
  /** Covered tokens: [kind, tokenHash]. */
  t: [PushKind, string][];
  iat: number;
  exp: number;
}

type Prefix = "ch1" | "c1" | "g1";

export class Signer {
  private constructor(
    private readonly current: CryptoKey,
    private readonly previous: CryptoKey | undefined,
  ) {}

  static async create(secret: string, previous?: string): Promise<Signer> {
    // 32 random bytes in base64 are 44 characters.
    if (!secret || secret.length < 43) throw new Error("RELAY_HMAC_KEY missing or too short");
    return new Signer(await hmacKey(secret), previous ? await hmacKey(previous) : undefined);
  }

  async seal(prefix: Prefix, body: object): Promise<string> {
    const head = `${prefix}.${toBase64Url(utf8.encode(JSON.stringify(body)))}`;
    return `${head}.${toBase64Url(await hmac(this.current, head))}`;
  }

  /** Returns the body if the MAC verifies under the current or previous key, else undefined. */
  async open<T>(prefix: Prefix, blob: string): Promise<T | undefined> {
    if (typeof blob !== "string" || blob.length > 4096) return undefined;
    const parts = blob.split(".");
    if (parts.length !== 3 || parts[0] !== prefix) return undefined;
    const head = `${parts[0]}.${parts[1]}`;
    let mac: Uint8Array;
    let json: unknown;
    try {
      mac = fromBase64Url(parts[2]!);
      json = JSON.parse(new TextDecoder().decode(fromBase64Url(parts[1]!)));
    } catch {
      return undefined;
    }
    for (const key of [this.current, this.previous]) {
      if (key && equalBytes(await hmac(key, head), mac)) return json as T;
    }
    return undefined;
  }
}

/**
 * Token hash bound into grants (PUSH-001 R33). The iPhone computes the same:
 * base64url(first 16 bytes of SHA-256(UTF-8 "levels-token-v1:" + lowercase hex token)).
 */
export async function tokenHash(hexToken: string): Promise<string> {
  const digest = await sha256(`levels-token-v1:${hexToken.toLowerCase()}`);
  return toBase64Url(digest.slice(0, 16));
}

/**
 * Device ID for rate limiting: first 16 bytes of SHA-256 of the decoded 32-byte App Attest
 * key ID, base64url. Derived from the bytes, never from the client's spelling of them.
 */
export async function deviceIdFromKeyId(keyIdBytes: Uint8Array): Promise<string> {
  return toBase64Url((await sha256(keyIdBytes)).slice(0, 16));
}

export function randomNonce(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(16)));
}
