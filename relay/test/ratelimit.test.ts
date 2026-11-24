import { describe, expect, it } from "vitest";
import { RateLimiterObject, applyHit, type LimiterState } from "../src/ratelimit.js";
import { T0 } from "./helpers.js";

describe("applyHit", () => {
  it("allows up to max per window, then reports when the window resets", () => {
    const s: LimiterState = {};
    const limits = [{ w: 3600, max: 3 }];
    expect(applyHit(s, T0, limits, 1).allowed).toBe(true);
    expect(applyHit(s, T0 + 10, limits, 1).allowed).toBe(true);
    expect(applyHit(s, T0 + 20, limits, 1).allowed).toBe(true);
    expect(applyHit(s, T0 + 30, limits, 1)).toEqual({ allowed: false, retryAfter: 3570 });
    expect(applyHit(s, T0 + 3600, limits, 1).allowed).toBe(true);
  });

  it("checks every window and only counts allowed hits", () => {
    const s: LimiterState = {};
    const limits = [
      { w: 60, max: 2 },
      { w: 3600, max: 3 },
    ];
    expect(applyHit(s, T0, limits, 1).allowed).toBe(true);
    expect(applyHit(s, T0, limits, 1).allowed).toBe(true);
    expect(applyHit(s, T0, limits, 1).allowed).toBe(false); // minute full
    expect(applyHit(s, T0 + 60, limits, 1).allowed).toBe(true); // 3rd in hour
    const d = applyHit(s, T0 + 120, limits, 1);
    expect(d.allowed).toBe(false); // hour full
    expect(d.retryAfter).toBe(3480);
  });

  it("charges a cost and refuses a cost larger than the limit", () => {
    const s: LimiterState = {};
    expect(applyHit(s, T0, [{ w: 60, max: 5 }], 4).allowed).toBe(true);
    expect(applyHit(s, T0, [{ w: 60, max: 5 }], 2).allowed).toBe(false);
    expect(applyHit({}, T0, [{ w: 60, max: 5 }], 6).allowed).toBe(false);
  });
});

class FakeStorage {
  data = new Map<string, unknown>();
  alarm?: number;
  async get<T>(k: string) {
    return this.data.get(k) as T | undefined;
  }
  async put(k: string, v: unknown) {
    this.data.set(k, structuredClone(v));
  }
  async deleteAll() {
    this.data.clear();
  }
  async setAlarm(t: number) {
    this.alarm = t;
  }
}

describe("RateLimiterObject", () => {
  const hit = (o: RateLimiterObject, body: unknown) =>
    o.fetch(new Request("https://limiter/hit", { method: "POST", body: JSON.stringify(body) }));

  it("persists counts, sets a cleanup alarm and forgets on alarm", async () => {
    const storage = new FakeStorage();
    let now = T0;
    const o = new RateLimiterObject({ storage }, undefined, () => now);
    const limits = [{ w: 3600, max: 1 }];
    expect(await (await hit(o, { limits })).json()).toEqual({ allowed: true, retryAfter: 0 });
    expect(storage.alarm).toBe((T0 + 3600 + 60) * 1000);
    now += 5;
    expect(((await (await hit(o, { limits })).json()) as { allowed: boolean }).allowed).toBe(false);
    await o.alarm();
    expect(storage.data.size).toBe(0);
  });

  it("rejects malformed limit requests", async () => {
    const o = new RateLimiterObject({ storage: new FakeStorage() });
    expect((await hit(o, { limits: [] })).status).toBe(400);
    expect((await hit(o, { limits: [{ w: 0, max: 1 }] })).status).toBe(400);
    expect((await hit(o, { limits: [{ w: 60, max: 1 }], cost: 0 })).status).toBe(400);
    expect((await o.fetch(new Request("https://limiter/hit", { method: "POST", body: "{" }))).status).toBe(400);
  });
});
