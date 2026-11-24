// APNs provider: ES256 provider JWT (cached ~50 min per key) and one HTTP/2
// POST per device token. PUSH-001 R20–R27.
//
// Apple: "Refresh your token no more than once every 20 minutes and no less
// than once every 60 minutes." We reuse a token for 50 minutes.

import { fromBase64, toBase64Url, utf8 } from "./bytes.js";
import type { Env } from "./env.js";

export type ApnsEnvironment = "development" | "production";
export type PushKind = "widget" | "liveActivity";

export const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  development: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

export const JWT_REUSE_SECONDS = 50 * 60;

export interface Clock {
  /** Unix time in seconds. */
  now(): number;
}

export const systemClock: Clock = { now: () => Math.floor(Date.now() / 1000) };

interface CachedJwt {
  jwt: string;
  iat: number;
}

/** Signs provider tokens and caches them per key ID for this isolate. */
export class ProviderTokenCache {
  private readonly cache = new Map<string, CachedJwt>();
  private readonly keys = new Map<string, Promise<CryptoKey>>();
  /** Number of JWTs signed; exposed for tests. */
  signCount = 0;

  constructor(private readonly clock: Clock = systemClock) {}

  async token(keyId: string, teamId: string, pem: string): Promise<string> {
    const now = this.clock.now();
    const cached = this.cache.get(keyId);
    if (cached && now - cached.iat < JWT_REUSE_SECONDS && now >= cached.iat) return cached.jwt;
    const jwt = await signProviderJwt(await this.key(keyId, pem), keyId, teamId, now);
    this.signCount++;
    this.cache.set(keyId, { jwt, iat: now });
    return jwt;
  }

  /** Drops a token APNs rejected (403 ExpiredProviderToken / InvalidProviderToken). */
  invalidate(keyId: string): void {
    this.cache.delete(keyId);
  }

  private key(keyId: string, pem: string): Promise<CryptoKey> {
    let k = this.keys.get(keyId);
    if (!k) {
      k = importP8(pem);
      this.keys.set(keyId, k);
      k.catch(() => this.keys.delete(keyId));
    }
    return k;
  }
}

export async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  return crypto.subtle.importKey(
    "pkcs8",
    fromBase64(body),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

export async function signProviderJwt(
  key: CryptoKey,
  keyId: string,
  teamId: string,
  iat: number,
): Promise<string> {
  const header = toBase64Url(utf8.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = toBase64Url(utf8.encode(JSON.stringify({ iss: teamId, iat })));
  const signingInput = `${header}.${claims}`;
  // WebCrypto ECDSA output is IEEE P1363 (r||s), which is what JWS ES256 wants.
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8.encode(signingInput)),
  );
  return `${signingInput}.${toBase64Url(sig)}`;
}

export interface ApnsKeyMaterial {
  keyId: string;
  pem: string;
}

/** Picks the key for an environment. Apple recommends one key per environment. */
export function keyFor(env: Env, apnsEnv: ApnsEnvironment): ApnsKeyMaterial | undefined {
  const keyId = apnsEnv === "production" ? env.APNS_KEY_ID_PRODUCTION : env.APNS_KEY_ID_SANDBOX;
  const pem = apnsEnv === "production" ? env.APNS_KEY_PRODUCTION : env.APNS_KEY_SANDBOX;
  if (!keyId || !pem) return undefined;
  return { keyId, pem };
}

export interface ApnsRequest {
  token: string; // lowercase hex
  env: ApnsEnvironment;
  kind: PushKind;
  body: string; // JSON payload, already size-checked
  priority?: 5 | 10;
  expiration: number;
}

export type ApnsOutcome =
  | "sent"
  | "unregistered"
  | "bad_token"
  | "throttled_by_apns"
  | "failed";

export interface ApnsResult {
  outcome: ApnsOutcome;
  status: number;
  reason?: string;
  apnsId?: string;
}

/** Anything that can POST to a URL; `fetch` in production, a fake in tests. */
export type Transport = (url: string, init: RequestInit) => Promise<Response>;

export function topicFor(bundleId: string, kind: PushKind): string {
  return kind === "widget"
    ? `${bundleId}.push-type.widgets`
    : `${bundleId}.push-type.liveactivity`;
}

export class ApnsClient {
  constructor(
    private readonly env: Env,
    private readonly tokens: ProviderTokenCache,
    private readonly transport: Transport,
  ) {}

  async send(req: ApnsRequest): Promise<ApnsResult> {
    const key = keyFor(this.env, req.env);
    if (!key) return { outcome: "failed", status: 0, reason: "NoKeyForEnvironment" };
    let result = await this.post(req, key);
    if (result.status === 403 && result.reason === "ExpiredProviderToken") {
      this.tokens.invalidate(key.keyId);
      result = await this.post(req, key);
    }
    return result;
  }

  private async post(req: ApnsRequest, key: ApnsKeyMaterial): Promise<ApnsResult> {
    const jwt = await this.tokens.token(key.keyId, this.env.APPLE_TEAM_ID, key.pem);
    const apnsId = crypto.randomUUID();
    const headers: Record<string, string> = {
      authorization: `bearer ${jwt}`,
      "apns-push-type": req.kind === "widget" ? "widgets" : "liveactivity",
      "apns-topic": topicFor(this.env.IOS_BUNDLE_ID, req.kind),
      "apns-id": apnsId,
      "apns-expiration": String(req.expiration),
      "content-type": "application/json",
    };
    if (req.priority !== undefined) headers["apns-priority"] = String(req.priority);
    let res: Response;
    try {
      res = await this.transport(`${APNS_HOSTS[req.env]}/3/device/${req.token}`, {
        method: "POST",
        headers,
        body: req.body,
      });
    } catch {
      return { outcome: "failed", status: 0, reason: "TransportError" };
    }
    let reason: string | undefined;
    if (res.status !== 200) {
      try {
        reason = ((await res.json()) as { reason?: string }).reason;
      } catch {
        reason = undefined;
      }
    }
    return { ...classify(res.status, reason), apnsId: res.headers.get("apns-id") ?? apnsId };
  }
}

export function classify(status: number, reason?: string): ApnsResult {
  if (status === 200) return { outcome: "sent", status };
  if (status === 410) return { outcome: "unregistered", status, reason };
  if (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) {
    return { outcome: "bad_token", status, reason };
  }
  if (status === 429) return { outcome: "throttled_by_apns", status, reason };
  return { outcome: "failed", status, reason };
}
