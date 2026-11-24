// Cross-check with the Swift client (PUSH-001 AC20). The same file is asserted by
// Shared/Tests/LevelsNetTests/PushAuthVectorTests.swift, so the relay and the Mac/iPhone code
// can't drift apart: signing string, body hash, token hash, key format, and a signature made by
// CryptoKit that the relay must accept (and one made by node:crypto the Swift side must accept).
import { describe, expect, it } from "vitest";
import vectors from "./vectors/push-auth-v1.json";
import { signingString } from "../src/auth.js";
import { fromBase64Url, sha256, toHex, utf8 } from "../src/bytes.js";
import { handle } from "../src/index.js";
import { tokenHash } from "../src/signed.js";
import { makeGrant, world } from "./helpers.js";

interface Vectors {
  macPublicKey: string;
  timestamp: string;
  method: string;
  path: string;
  token: string;
  body: string;
  bodySha256: string;
  signingString: string;
  signatures: { node: string; swift: string };
  tokenHashes: { token: string; hash: string }[];
}

const v: Vectors = vectors;

describe("push auth v1 shared vectors", () => {
  it("builds the same signing string and body hash", async () => {
    expect(toHex(await sha256(utf8.encode(v.body)))).toBe(v.bodySha256);
    expect(await signingString(v.timestamp, v.method, v.path, utf8.encode(v.body))).toBe(v.signingString);
  });

  it("computes the same token hashes", async () => {
    for (const t of v.tokenHashes) expect(await tokenHash(t.token)).toBe(t.hash);
  });

  it("verifies the CryptoKit and node signatures with the R18 public key", async () => {
    const raw = fromBase64Url(v.macPublicKey);
    expect(raw.length).toBe(65);
    expect(raw[0]).toBe(0x04);
    const key = await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    for (const sig of [v.signatures.swift, v.signatures.node]) {
      const bytes = fromBase64Url(sig);
      expect(bytes.length).toBe(64);
      expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, bytes, utf8.encode(v.signingString))).toBe(true);
    }
  });

  it.each(["swift", "node"] as const)("accepts the %s-signed request end to end", async (who) => {
    const w = await world();
    w.clock.t = Number(v.timestamp);
    const grant = await makeGrant(w, fromBase64Url(v.macPublicKey), [{ kind: "widget", token: v.token }]);
    const body = utf8.encode(v.body);
    const res = await handle(
      new Request(`https://relay.example${v.path}`, {
        method: v.method,
        headers: {
          "content-type": "application/json",
          "content-length": String(body.length),
          "levels-grant": grant,
          "levels-timestamp": v.timestamp,
          "levels-signature": v.signatures[who],
        },
        body,
      }),
      w.env,
      w.deps,
    );
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ results: [{ index: 0, status: "sent" }] });
  });
});
