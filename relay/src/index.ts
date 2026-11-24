// Levels push relay (ADR-0023, PUSH-001). Routes:
//   POST /v1/challenge    iPhone: one-time challenge for App Attest
//   POST /v1/attest       iPhone: attestation -> device credential
//   POST /v1/grant        iPhone: assertion -> push grant for its tokens and its Mac
//   POST /v1/widget-push  Mac: send widget / Live Activity pushes
//
// Privacy rules (ADR-0023 Decision 6): no console logging of requests, tokens,
// grants or payloads; nothing stored except rate-limit counters keyed by hashes.

import { ApnsClient, ProviderTokenCache, systemClock, type Clock, type Transport } from "./apns.js";
import { AttestError, verifyAssertion, verifyAttestation } from "./appattest.js";
import { AuthError, authenticatePush, coverageFor } from "./auth.js";
import { fromBase64, fromBase64Url, hmac, hmacKey, toBase64Url } from "./bytes.js";
import type { Env } from "./env.js";
import { DurableRateLimiter, LIMITS, type RateLimiter } from "./ratelimit.js";
import {
  CHALLENGE_TTL_SECONDS,
  CREDENTIAL_TTL_SECONDS,
  GRANT_TTL_SECONDS,
  MAX_GRANT_TOKENS,
  Signer,
  deviceIdFromKeyId,
  randomNonce,
  tokenHash,
  type ChallengeBody,
  type CredentialBody,
  type GrantBody,
} from "./signed.js";
import {
  BadRequest,
  MAX_BODY_BYTES,
  WIDGET_APNS_BODY,
  liveActivityApnsBody,
  parsePushRequest,
} from "./validate.js";

export { RateLimiterObject } from "./ratelimit.js";

export interface Deps {
  transport: Transport;
  limiter: RateLimiter;
  clock: Clock;
  tokens: ProviderTokenCache;
  /** Tests inject their own App Attest root. */
  attestRootPem?: string;
}

const sharedTokens = new ProviderTokenCache(systemClock);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, {
      transport: (url, init) => fetch(url, init),
      limiter: new DurableRateLimiter(env.RATE_LIMITER),
      clock: systemClock,
      tokens: sharedTokens,
    });
  },
};

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}

const err = (status: number, code: string, extra?: Record<string, string>) => json(status, { error: code }, extra);

async function readBody(request: Request): Promise<Uint8Array | undefined> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return undefined;
  const buf = new Uint8Array(await request.arrayBuffer());
  return buf.length > MAX_BODY_BYTES ? undefined : buf;
}

function parseJson(bytes: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    throw new BadRequest("json_invalid");
  }
}

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "POST") return err(405, "method_not_allowed", { allow: "POST" });
  const ctype = request.headers.get("content-type") ?? "";
  if (!ctype.toLowerCase().startsWith("application/json")) return err(400, "content_type");

  let signer: Signer;
  try {
    signer = await Signer.create(env.RELAY_HMAC_KEY, env.RELAY_HMAC_KEY_PREVIOUS);
  } catch {
    return err(500, "relay_misconfigured");
  }

  const body = await readBody(request);
  if (!body) return err(400, "body_too_large");

  try {
    switch (url.pathname) {
      case "/v1/widget-push":
        return await widgetPush(request, body, env, deps, signer);
      case "/v1/challenge":
        return await challenge(request, env, deps, signer);
      case "/v1/attest":
        return await attest(request, body, env, deps, signer);
      case "/v1/grant":
        return await grant(request, body, env, deps, signer);
      default:
        return err(404, "not_found");
    }
  } catch (e) {
    if (e instanceof BadRequest) return err(400, e.code);
    if (e instanceof AuthError) return err(401, e.code);
    if (e instanceof AttestError) return err(401, `attest_${e.code}`);
    return err(500, "internal");
  }
}

// ---------------------------------------------------------------- Mac route

type Status = "sent" | "unregistered" | "bad_token" | "rate_limited" | "throttled_by_apns" | "failed";

async function widgetPush(request: Request, body: Uint8Array, env: Env, deps: Deps, signer: Signer): Promise<Response> {
  const now = deps.clock.now();
  // 401 before 400: an unauthenticated caller learns nothing about validation.
  const auth = await authenticatePush(request.headers, body, "/v1/widget-push", signer, now);
  const push = parsePushRequest(parseJson(body), now);

  const hashes = await Promise.all(push.targets.map((t) => tokenHash(t.token)));
  const devices = new Set<string>();
  push.targets.forEach((t, i) => {
    const c = coverageFor(auth, t.kind, hashes[i]!, t.env);
    if (!c) throw new AuthError("token_not_granted");
    devices.add(c.dev);
  });

  // Whole-request limit per granting iPhone.
  for (const dev of devices) {
    const d = await deps.limiter.hit(`d:${dev}`, LIMITS.device, push.targets.length);
    if (!d.allowed) return err(429, "rate_limited", { "retry-after": String(d.retryAfter) });
  }

  const laBody = push.liveActivity ? liveActivityApnsBody(push.liveActivity, now) : undefined;
  const apns = new ApnsClient(env, deps.tokens, deps.transport);
  let minRetry = Number.POSITIVE_INFINITY;

  const results = await Promise.all(
    push.targets.map(async (t, index): Promise<{ index: number; status: Status }> => {
      const hash = hashes[index]!;
      const isLa = t.kind === "liveActivity";
      const limits = isLa ? LIMITS.liveActivityToken : LIMITS.widgetToken;
      let d = await deps.limiter.hit(`${isLa ? "la" : "w"}:${hash}`, limits);
      if (d.allowed && isLa && push.liveActivity!.priority === 10) {
        d = await deps.limiter.hit(`la10:${hash}`, LIMITS.liveActivityHighPriority);
      }
      if (!d.allowed) {
        minRetry = Math.min(minRetry, d.retryAfter);
        return { index, status: "rate_limited" };
      }
      const r = await apns.send({
        token: t.token,
        env: t.env,
        kind: t.kind,
        body: isLa ? laBody! : WIDGET_APNS_BODY,
        priority: isLa ? push.liveActivity!.priority : undefined,
        expiration: now + 3600,
      });
      return { index, status: r.outcome };
    }),
  );

  if (results.every((r) => r.status === "rate_limited")) {
    return err(429, "rate_limited", { "retry-after": String(Number.isFinite(minRetry) ? minRetry : 60) });
  }
  // Tokens APNs says are gone (410 Unregistered) or wrong (400 BadDeviceToken /
  // DeviceTokenNotForTopic). Echoed only to the Mac that sent them, never logged.
  const invalidTokens = results
    .filter((r) => r.status === "unregistered" || r.status === "bad_token")
    .map((r) => push.targets[r.index]!.token);
  if (invalidTokens.length === results.length) {
    return json(410, { error: "tokens_invalid", results, invalidTokens });
  }
  return json(202, invalidTokens.length > 0 ? { results, invalidTokens } : { results });
}

// ------------------------------------------------------------- iPhone routes

async function ipLimit(request: Request, env: Env, deps: Deps): Promise<Response | undefined> {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  // Keyed hash: the counter key can't be turned back into an address.
  const key = toBase64Url((await hmac(await hmacKey(env.RELAY_HMAC_KEY), `ip:${ip}`)).slice(0, 16));
  const d = await deps.limiter.hit(`ip:${key}`, [{ w: 3600, max: 60 }]);
  return d.allowed ? undefined : err(429, "rate_limited", { "retry-after": String(d.retryAfter) });
}

async function challenge(request: Request, env: Env, deps: Deps, signer: Signer): Promise<Response> {
  const limited = await ipLimit(request, env, deps);
  if (limited) return limited;
  const exp = deps.clock.now() + CHALLENGE_TTL_SECONDS;
  const body: ChallengeBody = { n: randomNonce(), exp };
  return json(200, { challenge: await signer.seal("ch1", body), expiresAt: exp });
}

async function openChallenge(signer: Signer, value: unknown, now: number): Promise<string> {
  if (typeof value !== "string") throw new BadRequest("challenge_missing");
  const c = await signer.open<ChallengeBody>("ch1", value);
  if (!c) throw new AuthError("challenge_invalid");
  if (c.exp <= now) throw new AuthError("challenge_expired");
  return value;
}

function appId(env: Env): string {
  return `${env.APPLE_TEAM_ID}.${env.IOS_BUNDLE_ID}`;
}

async function attest(request: Request, body: Uint8Array, env: Env, deps: Deps, signer: Signer): Promise<Response> {
  const limited = await ipLimit(request, env, deps);
  if (limited) return limited;
  const now = deps.clock.now();
  const b = parseJson(body) as Record<string, unknown>;
  if (typeof b !== "object" || b === null) throw new BadRequest("body_not_object");
  const challengeStr = await openChallenge(signer, b.challenge, now);
  if (typeof b.keyId !== "string" || typeof b.attestation !== "string") throw new BadRequest("fields_missing");
  let attestation: Uint8Array;
  try {
    attestation = fromBase64(b.attestation);
  } catch {
    throw new BadRequest("attestation_not_base64");
  }
  const result = await verifyAttestation({
    keyId: b.keyId,
    attestation,
    challenge: challengeStr,
    appId: appId(env),
    now: new Date(now * 1000),
    rootPem: deps.attestRootPem,
  });
  const cred: CredentialBody = {
    v: 1,
    kid: b.keyId,
    pk: toBase64Url(result.publicKeyRaw),
    env: result.env,
    iat: now,
    exp: now + CREDENTIAL_TTL_SECONDS,
  };
  return json(200, { credential: await signer.seal("c1", cred), env: result.env, expiresAt: cred.exp });
}

interface GrantClientData {
  challenge?: unknown;
  macKey?: unknown;
  tokens?: unknown;
}

async function grant(request: Request, body: Uint8Array, env: Env, deps: Deps, signer: Signer): Promise<Response> {
  const limited = await ipLimit(request, env, deps);
  if (limited) return limited;
  const now = deps.clock.now();
  const b = parseJson(body) as Record<string, unknown>;
  if (typeof b !== "object" || b === null) throw new BadRequest("body_not_object");
  if (typeof b.credential !== "string" || typeof b.clientData !== "string" || typeof b.assertion !== "string") {
    throw new BadRequest("fields_missing");
  }
  const cred = await signer.open<CredentialBody>("c1", b.credential);
  if (!cred || cred.v !== 1) throw new AuthError("credential_invalid");
  if (cred.exp <= now) throw new AuthError("credential_expired");

  let clientDataBytes: Uint8Array;
  let assertion: Uint8Array;
  try {
    clientDataBytes = fromBase64(b.clientData);
    assertion = fromBase64(b.assertion);
  } catch {
    throw new BadRequest("not_base64");
  }
  await verifyAssertion({
    assertion,
    clientData: clientDataBytes,
    publicKeyRaw: fromBase64Url(cred.pk),
    appId: appId(env),
  });

  const cd = parseJson(clientDataBytes) as GrantClientData;
  await openChallenge(signer, cd.challenge, now);

  if (typeof cd.macKey !== "string") throw new BadRequest("mac_key_missing");
  let macKeyBytes: Uint8Array;
  try {
    macKeyBytes = fromBase64Url(cd.macKey);
    if (macKeyBytes.length !== 65) throw new Error();
    await crypto.subtle.importKey("raw", macKeyBytes, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  } catch {
    throw new BadRequest("mac_key_invalid");
  }

  if (!Array.isArray(cd.tokens) || cd.tokens.length === 0 || cd.tokens.length > MAX_GRANT_TOKENS) {
    throw new BadRequest("tokens_invalid");
  }
  const t: GrantBody["t"] = cd.tokens.map((x) => {
    const e = x as { kind?: unknown; hash?: unknown };
    if (e.kind !== "widget" && e.kind !== "liveActivity") throw new BadRequest("kind_invalid");
    if (typeof e.hash !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(e.hash)) throw new BadRequest("hash_invalid");
    return [e.kind, e.hash];
  });

  const dev = await deviceIdFromKeyId(cred.kid);
  const d = await deps.limiter.hit(`g:${dev}`, [{ w: 3600, max: 30 }]);
  if (!d.allowed) return err(429, "rate_limited", { "retry-after": String(d.retryAfter) });

  const g: GrantBody = {
    v: 1,
    env: cred.env,
    mac: toBase64Url(macKeyBytes),
    dev,
    t,
    iat: now,
    exp: now + GRANT_TTL_SECONDS,
  };
  return json(200, { grant: await signer.seal("g1", g), env: g.env, expiresAt: g.exp });
}
