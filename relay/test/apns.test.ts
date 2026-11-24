import { describe, expect, it } from "vitest";
import {
  APNS_HOSTS,
  ApnsClient,
  JWT_REUSE_SECONDS,
  ProviderTokenCache,
  classify,
  topicFor,
} from "../src/apns.js";
import { fromBase64Url, utf8 } from "../src/bytes.js";
import { FakeClock, T0, p8Pair, world } from "./helpers.js";

function decodePart(part: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(fromBase64Url(part)));
}

describe("provider JWT", () => {
  it("is an ES256 JWT with kid, iss and iat that verifies with the key", async () => {
    const { pem, publicKey } = await p8Pair();
    const cache = new ProviderTokenCache(new FakeClock());
    const jwt = await cache.token("ABC123DEFG", "DEF123GHIJ", pem);
    const [h, c, s] = jwt.split(".");
    expect(decodePart(h!)).toEqual({ alg: "ES256", kid: "ABC123DEFG" });
    expect(decodePart(c!)).toEqual({ iss: "DEF123GHIJ", iat: T0 });
    const sig = fromBase64Url(s!);
    expect(sig.length).toBe(64); // raw r||s, as JWS requires
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      sig,
      utf8.encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });

  it("reuses a token for 50 minutes, then signs a new one", async () => {
    const { pem } = await p8Pair();
    const clock = new FakeClock();
    const cache = new ProviderTokenCache(clock);
    const first = await cache.token("K1", "T", pem);
    clock.t += 20 * 60;
    expect(await cache.token("K1", "T", pem)).toBe(first);
    clock.t = T0 + JWT_REUSE_SECONDS - 1;
    expect(await cache.token("K1", "T", pem)).toBe(first);
    expect(cache.signCount).toBe(1);
    clock.t = T0 + JWT_REUSE_SECONDS;
    const second = await cache.token("K1", "T", pem);
    expect(second).not.toBe(first);
    expect(decodePart(second.split(".")[1]!).iat).toBe(T0 + JWT_REUSE_SECONDS);
    expect(cache.signCount).toBe(2);
  });

  it("caches per key ID and re-signs after invalidate", async () => {
    const { pem } = await p8Pair();
    const cache = new ProviderTokenCache(new FakeClock());
    await cache.token("K1", "T", pem);
    await cache.token("K2", "T", pem);
    expect(cache.signCount).toBe(2);
    cache.invalidate("K1");
    await cache.token("K1", "T", pem);
    expect(cache.signCount).toBe(3);
  });

  it("re-signs if the clock goes backwards", async () => {
    const { pem } = await p8Pair();
    const clock = new FakeClock();
    const cache = new ProviderTokenCache(clock);
    await cache.token("K1", "T", pem);
    clock.t -= 10;
    await cache.token("K1", "T", pem);
    expect(cache.signCount).toBe(2);
  });
});

describe("APNs client", () => {
  it("routes development tokens to the sandbox host with the sandbox key", async () => {
    const w = await world();
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    const r = await c.send({ token: "ab".repeat(32), env: "development", kind: "widget", body: "{}", expiration: 1 });
    expect(r.outcome).toBe("sent");
    expect(w.calls[0]!.url).toBe(`${APNS_HOSTS.development}/3/device/${"ab".repeat(32)}`);
    const h = w.calls[0]!.init.headers as Record<string, string>;
    expect(decodePart(h.authorization!.slice(7).split(".")[0]!).kid).toBe("SANDBOX123");
  });

  it("routes production tokens to the production host with the production key", async () => {
    const w = await world();
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    await c.send({ token: "cd".repeat(32), env: "production", kind: "widget", body: "{}", expiration: 1 });
    expect(w.calls[0]!.url).toBe(`https://api.push.apple.com/3/device/${"cd".repeat(32)}`);
    const h = w.calls[0]!.init.headers as Record<string, string>;
    const [head, claims, sig] = h.authorization!.slice(7).split(".");
    expect(decodePart(head!).kid).toBe("PRODKEY123");
    expect(decodePart(claims!).iss).toBe("TEAM123456");
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      w.productionPub,
      fromBase64Url(sig!),
      utf8.encode(`${head}.${claims}`),
    );
    expect(ok).toBe(true);
  });

  it("sets widget headers per Apple's WidgetKit push docs and no priority", async () => {
    const w = await world();
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    await c.send({ token: "ab".repeat(32), env: "production", kind: "widget", body: "{}", expiration: 99 });
    const h = w.calls[0]!.init.headers as Record<string, string>;
    expect(h["apns-push-type"]).toBe("widgets");
    expect(h["apns-topic"]).toBe("com.example.levels.push-type.widgets");
    expect(h["apns-expiration"]).toBe("99");
    expect(h["apns-priority"]).toBeUndefined();
  });

  it("sets Live Activity headers and the requested priority", async () => {
    const w = await world();
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    await c.send({ token: "ab".repeat(32), env: "production", kind: "liveActivity", body: "{}", priority: 5, expiration: 1 });
    const h = w.calls[0]!.init.headers as Record<string, string>;
    expect(h["apns-push-type"]).toBe("liveactivity");
    expect(h["apns-topic"]).toBe("com.example.levels.push-type.liveactivity");
    expect(h["apns-priority"]).toBe("5");
  });

  it("fails closed when the environment has no key", async () => {
    const w = await world();
    w.env.APNS_KEY_SANDBOX = undefined;
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    const r = await c.send({ token: "ab".repeat(32), env: "development", kind: "widget", body: "{}", expiration: 1 });
    expect(r.outcome).toBe("failed");
    expect(w.calls).toHaveLength(0);
  });

  it("retries once with a fresh JWT on ExpiredProviderToken", async () => {
    const w = await world();
    let n = 0;
    w.respond = () =>
      n++ === 0
        ? Response.json({ reason: "ExpiredProviderToken" }, { status: 403 })
        : new Response(null, { status: 200 });
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    const r = await c.send({ token: "ab".repeat(32), env: "production", kind: "widget", body: "{}", expiration: 1 });
    expect(r.outcome).toBe("sent");
    expect(w.calls).toHaveLength(2);
    expect(w.deps.tokens.signCount).toBe(2);
  });

  it("maps a transport error to failed", async () => {
    const w = await world();
    w.deps.transport = async () => {
      throw new Error("h2 refused");
    };
    const c = new ApnsClient(w.env, w.deps.tokens, w.deps.transport);
    const r = await c.send({ token: "ab".repeat(32), env: "production", kind: "widget", body: "{}", expiration: 1 });
    expect(r.outcome).toBe("failed");
  });

  it("classifies APNs responses", () => {
    expect(classify(200).outcome).toBe("sent");
    expect(classify(410, "Unregistered").outcome).toBe("unregistered");
    expect(classify(400, "BadDeviceToken").outcome).toBe("bad_token");
    expect(classify(400, "DeviceTokenNotForTopic").outcome).toBe("bad_token");
    expect(classify(400, "BadTopic").outcome).toBe("failed");
    expect(classify(429, "TooManyRequests").outcome).toBe("throttled_by_apns");
    expect(classify(503).outcome).toBe("failed");
  });

  it("builds topics from the bundle ID", () => {
    expect(topicFor("com.a.b", "widget")).toBe("com.a.b.push-type.widgets");
    expect(topicFor("com.a.b", "liveActivity")).toBe("com.a.b.push-type.liveactivity");
  });
});
