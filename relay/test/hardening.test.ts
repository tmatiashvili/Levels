// Relay hardening (2026-11-24 security review): the body cap is enforced while streaming,
// Content-Length is required, and rate-limit identities come from decoded key bytes, not
// from the client's base64 spelling.
import { describe, expect, it } from "vitest";
import { fromBase64, fromBase64Url, toBase64, toBase64Url, utf8 } from "../src/bytes.js";
import { handle } from "../src/index.js";
import { deviceIdFromKeyId, tokenHash } from "../src/signed.js";
import { MAX_BODY_BYTES } from "../src/validate.js";
import {
  WIDGET_TOKEN,
  assertionObject,
  attestationObject,
  fakeAttestKit,
  fakeDevice,
  macKeyPair,
  post,
  world,
  type FakeAttestKit,
  type FakeDevice,
  type TestWorld,
} from "./helpers.js";

function streamRequest(stream: ReadableStream<Uint8Array>, headers: Record<string, string>): Request {
  return new Request("https://relay.example/v1/widget-push", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: stream,
    // Node needs this for a streamed request body.
    duplex: "half",
  } as RequestInit);
}

describe("body size cap", () => {
  it("411 when Content-Length is missing", async () => {
    const w = await world();
    const res = await handle(
      new Request("https://relay.example/v1/challenge", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      }),
      w.env,
      w.deps,
    );
    expect(res.status).toBe(411);
    expect(await res.json()).toEqual({ error: "length_required" });
  });

  it("411 for a malformed Content-Length", async () => {
    const w = await world();
    for (const bad of ["-1", "abc", "1e3", ""]) {
      const res = await post(w, "/v1/challenge", {}, { "content-length": bad });
      expect(res.status).toBe(411);
    }
  });

  it("400 without reading when the declared length is too big", async () => {
    const w = await world();
    let pulls = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(c) {
        pulls++;
        c.enqueue(new Uint8Array(1024));
      },
    });
    const res = await handle(streamRequest(stream, { "content-length": String(MAX_BODY_BYTES + 1) }), w.env, w.deps);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "body_too_large" });
    expect(pulls).toBeLessThanOrEqual(1); // at most the stream's own first prefetch
  });

  it("stops reading and cancels once a body passes the cap, whatever Content-Length said", async () => {
    const w = await world();
    let pulls = 0;
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      pull(c) {
        pulls++;
        c.enqueue(new Uint8Array(1024)); // never ends on its own
      },
      cancel() {
        cancelled = true;
      },
    });
    const res = await handle(streamRequest(stream, { "content-length": "10" }), w.env, w.deps);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "body_too_large" });
    expect(cancelled).toBe(true);
    expect(pulls).toBeLessThanOrEqual(MAX_BODY_BYTES / 1024 + 2);
  });

  it("accepts a body exactly at the cap (then fails later checks normally)", async () => {
    const w = await world();
    const res = await post(w, "/v1/widget-push", " ".repeat(MAX_BODY_BYTES));
    expect(res.status).toBe(401); // reached auth: the size check passed
  });
});

async function attest(w: TestWorld, kit: FakeAttestKit, dev: FakeDevice, keyId: string): Promise<Response> {
  const ch = (await (await post(w, "/v1/challenge", {})).json()) as { challenge: string };
  const att = await attestationObject(kit, dev, ch.challenge);
  return post(w, "/v1/attest", { keyId, attestation: toBase64(att), challenge: ch.challenge });
}

function blobJson<T>(blob: string): T {
  return JSON.parse(new TextDecoder().decode(fromBase64Url(blob.split(".")[1]!))) as T;
}

describe("rate-limit identity comes from key bytes", () => {
  it("base64 spellings of one key ID share one device ID and one grant bucket", async () => {
    const w = await world();
    const kit = await fakeAttestKit();
    w.deps.attestRootPem = kit.rootPem;
    const dev = await fakeDevice();
    const mac = await macKeyPair();
    const bytes = fromBase64(dev.keyId);
    const spellings = [dev.keyId, toBase64Url(bytes), dev.keyId.replace(/=+$/, "")];
    expect(new Set(spellings).size).toBeGreaterThan(1);

    const grants: string[] = [];
    for (const spelling of spellings) {
      const a = await attest(w, kit, dev, spelling);
      expect(a.status).toBe(200);
      const { credential } = (await a.json()) as { credential: string };
      // The credential stores the canonical spelling.
      expect(blobJson<{ kid: string }>(credential).kid).toBe(toBase64(bytes));
      const ch = (await (await post(w, "/v1/challenge", {})).json()) as { challenge: string };
      const cd = utf8.encode(
        JSON.stringify({
          challenge: ch.challenge,
          macKey: toBase64Url(mac.rawPub),
          tokens: [{ kind: "widget", hash: await tokenHash(WIDGET_TOKEN) }],
        }),
      );
      const g = await post(w, "/v1/grant", {
        credential,
        clientData: toBase64(cd),
        assertion: toBase64(await assertionObject(dev, cd)),
      });
      expect(g.status).toBe(200);
      grants.push(((await g.json()) as { grant: string }).grant);
    }
    const expected = await deviceIdFromKeyId(bytes);
    expect(grants.map((g) => blobJson<{ dev: string }>(g).dev)).toEqual(spellings.map(() => expected));
    // All three grants were counted in the same bucket.
    const bucket = w.limiter.states.get(`g:${expected}`) as Record<string, { count: number }>;
    expect(bucket["3600"]!.count).toBe(3);
  });

  it("rejects a key ID that doesn't decode to 32 bytes", async () => {
    const w = await world();
    const kit = await fakeAttestKit();
    w.deps.attestRootPem = kit.rootPem;
    const dev = await fakeDevice();
    for (const bad of [toBase64(new Uint8Array(31)), toBase64(new Uint8Array(33)), "not base64!"]) {
      const res = await attest(w, kit, dev, bad);
      expect(res.status).toBe(400);
      expect(await res.json()).toEqual({ error: "key_id_invalid" });
    }
  });
});
