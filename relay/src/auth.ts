// Authentication of POST /v1/widget-push (PUSH-001 R17–R19, "Mac request
// authentication"). The Mac proves two things:
//   1. an attested Levels iPhone granted it these tokens (Levels-Grant), and
//   2. it holds the private key named in the grant (Levels-Signature over the
//      timestamp, method, path and body hash).

import { fromBase64Url, sha256, toHex, utf8 } from "./bytes.js";
import type { ApnsEnvironment, PushKind } from "./apns.js";
import type { GrantBody, Signer } from "./signed.js";

export const SIGNATURE_CONTEXT = "levels-push-v1";
export const MAX_CLOCK_SKEW_SECONDS = 300;
export const MAX_GRANTS_PER_REQUEST = 4;

export class AuthError extends Error {
  constructor(public readonly code: string) {
    super(code);
  }
}

export interface Coverage {
  env: ApnsEnvironment;
  dev: string;
}

export interface AuthContext {
  /** "kind:tokenHash" -> grant facts. */
  covered: Map<string, Coverage[]>;
  devices: Set<string>;
}

export async function signingString(timestamp: string, method: string, path: string, body: Uint8Array): Promise<string> {
  return `${SIGNATURE_CONTEXT}\n${timestamp}\n${method}\n${path}\n${toHex(await sha256(body))}`;
}

export async function authenticatePush(
  headers: Headers,
  body: Uint8Array,
  path: string,
  signer: Signer,
  now: number,
): Promise<AuthContext> {
  const grantHeader = headers.get("levels-grant");
  const ts = headers.get("levels-timestamp");
  const sig = headers.get("levels-signature");
  if (!grantHeader || !ts || !sig) throw new AuthError("auth_missing");

  if (!/^\d{1,11}$/.test(ts)) throw new AuthError("timestamp_invalid");
  if (Math.abs(Number(ts) - now) > MAX_CLOCK_SKEW_SECONDS) throw new AuthError("timestamp_skew");

  const blobs = grantHeader.split(",").map((g) => g.trim()).filter((g) => g.length > 0);
  if (blobs.length === 0 || blobs.length > MAX_GRANTS_PER_REQUEST) throw new AuthError("grant_count");

  const grants: GrantBody[] = [];
  for (const blob of blobs) {
    const g = await signer.open<GrantBody>("g1", blob);
    if (!g || g.v !== 1 || !Array.isArray(g.t) || typeof g.mac !== "string") throw new AuthError("grant_invalid");
    if (typeof g.exp !== "number" || g.exp <= now) throw new AuthError("grant_expired");
    grants.push(g);
  }
  const macKey = grants[0]!.mac;
  if (!grants.every((g) => g.mac === macKey)) throw new AuthError("grant_mac_mismatch");

  let sigBytes: Uint8Array;
  let keyBytes: Uint8Array;
  try {
    sigBytes = fromBase64Url(sig);
    keyBytes = fromBase64Url(macKey);
  } catch {
    throw new AuthError("signature_invalid");
  }
  if (sigBytes.length !== 64 || keyBytes.length !== 65) throw new AuthError("signature_invalid");
  let ok = false;
  try {
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "ECDSA", namedCurve: "P-256" }, false, [
      "verify",
    ]);
    ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      sigBytes,
      utf8.encode(await signingString(ts, "POST", path, body)),
    );
  } catch {
    ok = false;
  }
  if (!ok) throw new AuthError("signature_invalid");

  const covered = new Map<string, Coverage[]>();
  const devices = new Set<string>();
  for (const g of grants) {
    devices.add(g.dev);
    for (const [kind, hash] of g.t) {
      const k = `${kind}:${hash}`;
      const list = covered.get(k) ?? [];
      list.push({ env: g.env, dev: g.dev });
      covered.set(k, list);
    }
  }
  return { covered, devices };
}

export function coverageFor(ctx: AuthContext, kind: PushKind, hash: string, env: ApnsEnvironment): Coverage | undefined {
  return ctx.covered.get(`${kind}:${hash}`)?.find((c) => c.env === env);
}
