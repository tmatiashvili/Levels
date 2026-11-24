// LIVE-001 R30: cross-check of the Live Activity request with the Swift side. The same file is
// asserted by Shared/Tests/LevelsNetTests/LiveActivityVectorTests.swift (which checks that the
// Mac encodes exactly `body` and the iPhone decodes the `content-state` of `apnsBody`), so the
// Mac's pushes and the relay can't drift apart. No new wire fields: the relay already treats
// `content-state` as an opaque object (PUSH-001 R10).
import { describe, expect, it } from "vitest";
import vectors from "./vectors/live-activity-v1.json";
import { liveActivityApnsBody, parsePushRequest } from "../src/validate.js";
import { macKeyPair, makeGrant, signedPush, world } from "./helpers.js";

interface Vector {
  now: number;
  token: string;
  env: "development" | "production";
  priority: 5 | 10;
  body: string;
  apnsBody: string;
}

const v: Vector = vectors as Vector;

describe("Live Activity shared vector", () => {
  it("parses the Swift body and builds the expected APNs body", () => {
    const req = parsePushRequest(JSON.parse(v.body), v.now);
    expect(req.targets).toEqual([{ token: v.token, env: v.env, kind: "liveActivity" }]);
    expect(req.liveActivity?.priority).toBe(v.priority);
    const aps = liveActivityApnsBody(req.liveActivity!, v.now);
    expect(aps).toBe(v.apnsBody);
    expect(new TextEncoder().encode(aps).length).toBeLessThan(4096);
  });

  it("sends it end to end as a liveactivity push with the vector's priority", async () => {
    const w = await world();
    w.clock.t = v.now;
    const mac = await macKeyPair();
    const grant = await makeGrant(w, mac.rawPub, [{ kind: "liveActivity", token: v.token }], { env: v.env });
    const res = await signedPush(w, mac, grant, v.body);
    expect(res.status).toBe(202);
    expect(w.calls).toHaveLength(1);
    const headers = new Headers(w.calls[0].init.headers);
    expect(headers.get("apns-push-type")).toBe("liveactivity");
    expect(headers.get("apns-topic")).toBe("com.example.levels.push-type.liveactivity");
    expect(headers.get("apns-priority")).toBe(String(v.priority));
    expect(w.calls[0].url).toContain("api.sandbox.push.apple.com");
    expect(w.calls[0].init.body).toBe(v.apnsBody);
  });
});
