import { beforeEach, describe, expect, it } from "vitest";
import { LA_TOKEN, WIDGET_TOKEN, macKeyPair, makeGrant, post, signedPush, world, type TestWorld } from "./helpers.js";

let w: TestWorld;
let mac: Awaited<ReturnType<typeof macKeyPair>>;
let grant: string;
const widgetBody = { tokens: [{ token: WIDGET_TOKEN, env: "production", kind: "widget" }] };

beforeEach(async () => {
  w = await world();
  mac = await macKeyPair();
  grant = await makeGrant(w, mac.rawPub, [
    { kind: "widget", token: WIDGET_TOKEN },
    { kind: "liveActivity", token: LA_TOKEN },
  ]);
});

describe("POST /v1/widget-push: success", () => {
  it("returns 202 with one result per token and sends the widget push", async () => {
    const res = await signedPush(w, mac, grant, widgetBody);
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ results: [{ index: 0, status: "sent" }] });
    expect(w.calls).toHaveLength(1);
    expect(w.calls[0]!.url).toBe(`https://api.push.apple.com/3/device/${WIDGET_TOKEN}`);
    expect(JSON.parse(w.calls[0]!.init.body as string)).toEqual({ aps: { "content-changed": true } });
  });

  it("sends Live Activity content-state with priority 10 when asked", async () => {
    const res = await signedPush(w, mac, grant, {
      tokens: [{ token: LA_TOKEN, env: "production", kind: "liveActivity" }],
      payload: { "content-state": { levels: [64, 12] }, priority: 10, "stale-date": w.clock.now() + 1800 },
    });
    expect(res.status).toBe(202);
    const h = w.calls[0]!.init.headers as Record<string, string>;
    expect(h["apns-priority"]).toBe("10");
    expect(JSON.parse(w.calls[0]!.init.body as string)).toEqual({
      aps: {
        timestamp: w.clock.now(),
        event: "update",
        "content-state": { levels: [64, 12] },
        "stale-date": w.clock.now() + 1800,
      },
    });
  });

  it("returns 410 with invalidTokens when every token is gone", async () => {
    w.respond = () => Response.json({ reason: "Unregistered" }, { status: 410 });
    const res = await signedPush(w, mac, grant, widgetBody);
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({
      error: "tokens_invalid",
      results: [{ index: 0, status: "unregistered" }],
      invalidTokens: [WIDGET_TOKEN],
    });
  });

  it("lists invalid tokens in a 202 when others were sent", async () => {
    w.respond = (url) =>
      url.endsWith(WIDGET_TOKEN)
        ? Response.json({ reason: "BadDeviceToken" }, { status: 400 })
        : new Response(null, { status: 200 });
    const res = await signedPush(w, mac, grant, {
      tokens: [
        { token: WIDGET_TOKEN.toUpperCase(), env: "production", kind: "widget" },
        { token: LA_TOKEN, env: "production", kind: "liveActivity" },
      ],
      payload: { "content-state": { l: 1 } },
    });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({
      results: [
        { index: 0, status: "bad_token" },
        { index: 1, status: "sent" },
      ],
      invalidTokens: [WIDGET_TOKEN], // lowercase hex
    });
  });

  it("omits invalidTokens when all were sent, and ignores a widget payload", async () => {
    const res = await signedPush(w, mac, grant, { ...widgetBody, payload: { aps: { "content-changed": true } } });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({ results: [{ index: 0, status: "sent" }] });
  });

  it("accepts grants from two iPhones signed for the same Mac", async () => {
    const other = "c".repeat(64);
    const g2 = await makeGrant(w, mac.rawPub, [{ kind: "widget", token: other }], { dev: "device-two-0000000" });
    const res = await signedPush(w, mac, `${grant}, ${g2}`, {
      tokens: [
        { token: WIDGET_TOKEN, env: "production", kind: "widget" },
        { token: other, env: "production", kind: "widget" },
      ],
    });
    expect(res.status).toBe(202);
    expect(w.calls).toHaveLength(2);
  });

  it("routes a development grant's tokens to the sandbox", async () => {
    const g = await makeGrant(w, mac.rawPub, [{ kind: "widget", token: WIDGET_TOKEN }], { env: "development" });
    const res = await signedPush(w, mac, g, { tokens: [{ token: WIDGET_TOKEN, env: "development", kind: "widget" }] });
    expect(res.status).toBe(202);
    expect(w.calls[0]!.url).toContain("https://api.sandbox.push.apple.com/3/device/");
  });
});

describe("POST /v1/widget-push: auth failures (401)", () => {
  const expect401 = async (res: Response, code: string) => {
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: code });
    expect(w.calls).toHaveLength(0);
  };

  it("missing auth headers", async () => {
    await expect401(await post(w, "/v1/widget-push", widgetBody), "auth_missing");
  });

  it("forged grant", async () => {
    const forged = await makeGrant(w, mac.rawPub, [{ kind: "widget", token: WIDGET_TOKEN }], {
      key: "c29tZS1vdGhlci1rZXktc29tZS1vdGhlci1rZXktMTIzNDU2Nzg=",
    });
    await expect401(await signedPush(w, mac, forged, widgetBody), "grant_invalid");
  });

  it("expired grant", async () => {
    const g = await makeGrant(w, mac.rawPub, [{ kind: "widget", token: WIDGET_TOKEN }], { exp: w.clock.now() });
    await expect401(await signedPush(w, mac, g, widgetBody), "grant_expired");
  });

  it("signature from a different Mac key", async () => {
    const stranger = await macKeyPair();
    await expect401(await signedPush(w, stranger, grant, widgetBody), "signature_invalid");
  });

  it("body changed after signing", async () => {
    await expect401(await signedPush(w, mac, grant, widgetBody, { tamper: true }), "signature_invalid");
  });

  it("timestamp more than 5 minutes off", async () => {
    await expect401(await signedPush(w, mac, grant, widgetBody, { ts: w.clock.now() - 301 }), "timestamp_skew");
  });

  it("token not in the grant", async () => {
    await expect401(
      await signedPush(w, mac, grant, { tokens: [{ token: "d".repeat(64), env: "production", kind: "widget" }] }),
      "token_not_granted",
    );
  });

  it("token granted for another kind", async () => {
    await expect401(
      await signedPush(w, mac, grant, {
        tokens: [{ token: WIDGET_TOKEN, env: "production", kind: "liveActivity" }],
        payload: { "content-state": {} },
      }),
      "token_not_granted",
    );
  });

  it("production grant used for a development token", async () => {
    await expect401(
      await signedPush(w, mac, grant, { tokens: [{ token: WIDGET_TOKEN, env: "development", kind: "widget" }] }),
      "token_not_granted",
    );
  });

  it("grants for two different Macs in one request", async () => {
    const other = await macKeyPair();
    const g2 = await makeGrant(w, other.rawPub, [{ kind: "widget", token: "c".repeat(64) }]);
    await expect401(await signedPush(w, mac, `${grant},${g2}`, widgetBody), "grant_mac_mismatch");
  });

  it("unauthenticated garbage gets 401, not 400", async () => {
    const res = await post(w, "/v1/widget-push", "not json", { "levels-grant": "x", "levels-timestamp": "1", "levels-signature": "x" });
    expect(res.status).toBe(401);
  });
});

describe("POST /v1/widget-push: bad body (400)", () => {
  it("rejects a bad body from an authenticated Mac", async () => {
    const res = await signedPush(w, mac, grant, { tokens: [{ token: "xyz", env: "production", kind: "widget" }] });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "token_invalid" });
  });

  it("rejects invalid JSON", async () => {
    const res = await signedPush(w, mac, grant, "{nope");
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "json_invalid" });
  });

  it("rejects a non-JSON content type and oversized bodies", async () => {
    const res = await post(w, "/v1/widget-push", widgetBody, { "content-type": "text/plain" });
    expect(res.status).toBe(400);
    const big = await post(w, "/v1/widget-push", "x".repeat(9000));
    expect(big.status).toBe(400);
    expect(await big.json()).toEqual({ error: "body_too_large" });
  });
});

describe("POST /v1/widget-push: rate limits (429)", () => {
  it("limits widget pushes per token to 12 per hour", async () => {
    for (let i = 0; i < 12; i++) {
      w.clock.t += 1;
      expect((await signedPush(w, mac, grant, widgetBody)).status).toBe(202);
    }
    w.clock.t += 1;
    const res = await signedPush(w, mac, grant, widgetBody);
    expect(res.status).toBe(429);
    expect(Number(res.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(w.calls).toHaveLength(12);
  });

  it("reports a limited token inside 202 when others still go out", async () => {
    for (let i = 0; i < 12; i++) await signedPush(w, mac, grant, widgetBody);
    const res = await signedPush(w, mac, grant, {
      tokens: [
        { token: WIDGET_TOKEN, env: "production", kind: "widget" },
        { token: LA_TOKEN, env: "production", kind: "liveActivity" },
      ],
      payload: { "content-state": { l: 1 } },
    });
    expect(res.status).toBe(202);
    expect(await res.json()).toEqual({
      results: [
        { index: 0, status: "rate_limited" },
        { index: 1, status: "sent" },
      ],
    });
  });

  it("limits priority-10 Live Activity pushes separately", async () => {
    const body = (priority: 5 | 10) => ({
      tokens: [{ token: LA_TOKEN, env: "production", kind: "liveActivity" }],
      payload: { "content-state": { l: 1 }, priority },
    });
    for (let i = 0; i < 12; i++) expect((await signedPush(w, mac, grant, body(10))).status).toBe(202);
    expect((await signedPush(w, mac, grant, body(10))).status).toBe(429);
    expect((await signedPush(w, mac, grant, body(5))).status).toBe(202);
  });

  it("limits the whole request per granting iPhone", async () => {
    w.limiter.states.set("d:device-one-00000000", { "3600": { start: w.clock.now(), count: 400 } });
    const res = await signedPush(w, mac, grant, widgetBody);
    expect(res.status).toBe(429);
    expect(w.calls).toHaveLength(0);
  });
});

describe("routing", () => {
  it("404 for unknown paths, 405 for GET", async () => {
    expect((await post(w, "/v1/nope", {})).status).toBe(404);
    const get = await (await import("../src/index.js")).handle(
      new Request("https://relay.example/v1/widget-push"),
      w.env,
      w.deps,
    );
    expect(get.status).toBe(405);
  });

  it("500 when the relay has no HMAC key", async () => {
    w.env.RELAY_HMAC_KEY = "";
    expect((await signedPush(w, mac, grant, widgetBody)).status).toBe(500);
  });
});
