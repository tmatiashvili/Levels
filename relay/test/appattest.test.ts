import { describe, expect, it } from "vitest";
import { AttestError, derToRawSignature, verifyAssertion, verifyAttestation } from "../src/appattest.js";
import { toBase64, toBase64Url, utf8 } from "../src/bytes.js";
import { tokenHash } from "../src/signed.js";
import {
  AAGUID_DEV,
  APP_ID,
  T0,
  WIDGET_TOKEN,
  assertionObject,
  attestationObject,
  fakeAttestKit,
  fakeDevice,
  macKeyPair,
  post,
  rawToDer,
  signedPush,
  world,
  type Enc,
} from "./helpers.js";

const now = new Date(T0 * 1000);

async function code(p: Promise<unknown>): Promise<string> {
  try {
    await p;
    return "ok";
  } catch (e) {
    if (e instanceof AttestError) return e.code;
    throw e;
  }
}

describe("verifyAttestation", () => {
  it("accepts a valid production attestation and returns the key", async () => {
    const kit = await fakeAttestKit();
    const dev = await fakeDevice();
    const att = await attestationObject(kit, dev, "challenge-1");
    const r = await verifyAttestation({ keyId: dev.keyId, attestation: att, challenge: "challenge-1", appId: APP_ID, now, rootPem: kit.rootPem });
    expect(r.env).toBe("production");
    expect(r.publicKeyRaw).toEqual(dev.rawPub);
  });

  it("maps the development aaguid to the development environment", async () => {
    const kit = await fakeAttestKit();
    const dev = await fakeDevice();
    const att = await attestationObject(kit, dev, "c", { aaguid: AAGUID_DEV });
    const r = await verifyAttestation({ keyId: dev.keyId, attestation: att, challenge: "c", appId: APP_ID, now, rootPem: kit.rootPem });
    expect(r.env).toBe("development");
  });

  it("rejects the real Apple root for a fake chain", async () => {
    const kit = await fakeAttestKit();
    const dev = await fakeDevice();
    const att = await attestationObject(kit, dev, "c");
    expect(await code(verifyAttestation({ keyId: dev.keyId, attestation: att, challenge: "c", appId: APP_ID, now }))).toBe("chain");
  });

  it.each([
    ["another challenge", {}, { challenge: "other" }, "nonce"],
    ["a wrong nonce", { wrongNonce: true }, {}, "nonce"],
    ["another app", { appId: "TEAM123456.com.evil" }, {}, "rp_id"],
    ["a nonzero counter", { counter: 1 }, {}, "counter"],
    ["an unknown aaguid", { aaguid: new Uint8Array(16) }, {}, "aaguid"],
    ["a mismatched credential ID", { credId: new Uint8Array(32) }, {}, "credential_id"],
    ["a Developer ID validation category", { extensions: new Map<Enc, Enc>([["apple_validation_category_01", 6]]) }, {}, "validation_category"],
  ])("rejects %s", async (_n, attOpts, inputOpts, expected) => {
    const kit = await fakeAttestKit();
    const dev = await fakeDevice();
    const att = await attestationObject(kit, dev, "c", attOpts as never);
    const input = { keyId: dev.keyId, attestation: att, challenge: "c", appId: APP_ID, now, rootPem: kit.rootPem, ...inputOpts };
    expect(await code(verifyAttestation(input))).toBe(expected);
  });

  it("accepts an App Store validation category", async () => {
    const kit = await fakeAttestKit();
    const dev = await fakeDevice();
    const att = await attestationObject(kit, dev, "c", { extensions: new Map<Enc, Enc>([["apple_validation_category_01", 4]]) });
    const r = await verifyAttestation({ keyId: dev.keyId, attestation: att, challenge: "c", appId: APP_ID, now, rootPem: kit.rootPem });
    expect(r.env).toBe("production");
  });

  it("rejects a key ID that isn't the hash of the certificate key", async () => {
    const kit = await fakeAttestKit();
    const dev = await fakeDevice();
    const other = await fakeDevice();
    const att = await attestationObject(kit, dev, "c");
    expect(await code(verifyAttestation({ keyId: other.keyId, attestation: att, challenge: "c", appId: APP_ID, now, rootPem: kit.rootPem }))).toBe("key_id");
  });

  it("rejects garbage", async () => {
    expect(await code(verifyAttestation({ keyId: "x", attestation: new Uint8Array([0xff]), challenge: "c", appId: APP_ID, now }))).toBe("cbor");
  });
});

describe("verifyAssertion", () => {
  it("accepts a valid assertion and returns the counter", async () => {
    const dev = await fakeDevice();
    const cd = utf8.encode('{"challenge":"x"}');
    const a = await assertionObject(dev, cd);
    expect(await verifyAssertion({ assertion: a, clientData: cd, publicKeyRaw: dev.rawPub, appId: APP_ID })).toBe(1);
  });

  it("rejects a bad signature, other client data, another app and counter 0", async () => {
    const dev = await fakeDevice();
    const cd = utf8.encode("{}");
    const base = { clientData: cd, publicKeyRaw: dev.rawPub, appId: APP_ID };
    expect(await code(verifyAssertion({ ...base, assertion: await assertionObject(dev, cd, { badSig: true }) }))).toBe("signature");
    expect(await code(verifyAssertion({ ...base, assertion: await assertionObject(dev, utf8.encode("[]")) }))).toBe("signature");
    expect(await code(verifyAssertion({ ...base, assertion: await assertionObject(dev, cd, { appId: "X.y" }) }))).toBe("rp_id");
    expect(await code(verifyAssertion({ ...base, assertion: await assertionObject(dev, cd, { counter: 0 }) }))).toBe("counter");
  });

  it("converts DER signatures with leading zero bytes", () => {
    const raw = new Uint8Array(64);
    raw[0] = 0x80;
    raw[40] = 0x01;
    expect(derToRawSignature(rawToDer(raw))).toEqual(raw);
  });
});

describe("iPhone flow: challenge -> attest -> grant -> Mac push", () => {
  it("issues a grant an attested iPhone can hand to its Mac", async () => {
    const w = await world();
    const kit = await fakeAttestKit();
    w.deps.attestRootPem = kit.rootPem;
    const dev = await fakeDevice();
    const mac = await macKeyPair();

    const ch1 = (await (await post(w, "/v1/challenge", {})).json()) as { challenge: string };
    const att = await attestationObject(kit, dev, ch1.challenge);
    const attRes = await post(w, "/v1/attest", { keyId: dev.keyId, attestation: toBase64(att), challenge: ch1.challenge });
    expect(attRes.status).toBe(200);
    const { credential, env } = (await attRes.json()) as { credential: string; env: string };
    expect(env).toBe("production");

    const ch2 = (await (await post(w, "/v1/challenge", {})).json()) as { challenge: string };
    const clientData = utf8.encode(
      JSON.stringify({
        challenge: ch2.challenge,
        macKey: toBase64Url(mac.rawPub),
        tokens: [{ kind: "widget", hash: await tokenHash(WIDGET_TOKEN) }],
      }),
    );
    const assertion = await assertionObject(dev, clientData);
    const gRes = await post(w, "/v1/grant", { credential, clientData: toBase64(clientData), assertion: toBase64(assertion) });
    expect(gRes.status).toBe(200);
    const { grant, expiresAt } = (await gRes.json()) as { grant: string; expiresAt: number };
    expect(expiresAt).toBe(T0 + 30 * 24 * 3600);

    const push = await signedPush(w, mac, grant, { tokens: [{ token: WIDGET_TOKEN, env: "production", kind: "widget" }] });
    expect(push.status).toBe(202);
    expect(w.calls).toHaveLength(1);
  });

  it("rejects an expired challenge, a forged credential and a bad assertion", async () => {
    const w = await world();
    const kit = await fakeAttestKit();
    w.deps.attestRootPem = kit.rootPem;
    const dev = await fakeDevice();

    const ch = (await (await post(w, "/v1/challenge", {})).json()) as { challenge: string };
    w.clock.t += 301;
    const att = await attestationObject(kit, dev, ch.challenge);
    const late = await post(w, "/v1/attest", { keyId: dev.keyId, attestation: toBase64(att), challenge: ch.challenge });
    expect(late.status).toBe(401);
    expect(await late.json()).toEqual({ error: "challenge_expired" });

    const forged = await post(w, "/v1/grant", { credential: "c1.e30.AAAA", clientData: "e30=", assertion: "oA==" });
    expect(forged.status).toBe(401);
    expect(await forged.json()).toEqual({ error: "credential_invalid" });

    const ch2 = (await (await post(w, "/v1/challenge", {})).json()) as { challenge: string };
    const att2 = await attestationObject(kit, dev, ch2.challenge);
    const { credential } = (await (await post(w, "/v1/attest", { keyId: dev.keyId, attestation: toBase64(att2), challenge: ch2.challenge })).json()) as { credential: string };
    const cd = utf8.encode(JSON.stringify({ challenge: ch2.challenge, macKey: "x", tokens: [] }));
    const bad = await post(w, "/v1/grant", { credential, clientData: toBase64(cd), assertion: toBase64(await assertionObject(dev, cd, { badSig: true })) });
    expect(bad.status).toBe(401);
    expect(await bad.json()).toEqual({ error: "attest_signature" });
  });

  it("rate limits challenges per IP", async () => {
    const w = await world();
    for (let i = 0; i < 60; i++) expect((await post(w, "/v1/challenge", {}, { "cf-connecting-ip": "203.0.113.9" })).status).toBe(200);
    expect((await post(w, "/v1/challenge", {}, { "cf-connecting-ip": "203.0.113.9" })).status).toBe(429);
    expect((await post(w, "/v1/challenge", {}, { "cf-connecting-ip": "203.0.113.10" })).status).toBe(200);
  });
});
