import { describe, expect, it } from "vitest";
import {
  BadRequest,
  WIDGET_APNS_BODY,
  liveActivityApnsBody,
  parsePushRequest,
} from "../src/validate.js";
import { T0 } from "./helpers.js";

const tok = (c = "a", n = 64) => c.repeat(n);
const code = (f: () => unknown) => {
  try {
    f();
  } catch (e) {
    if (e instanceof BadRequest) return e.code;
    throw e;
  }
  return "ok";
};

describe("parsePushRequest", () => {
  it("accepts a widget request and lowercases tokens", () => {
    const r = parsePushRequest({ tokens: [{ token: tok("A"), env: "production", kind: "widget" }] }, T0);
    expect(r.targets).toEqual([{ token: tok("a"), env: "production", kind: "widget" }]);
    expect(r.liveActivity).toBeUndefined();
  });

  it("accepts a Live Activity request with content-state and defaults", () => {
    const r = parsePushRequest(
      {
        tokens: [{ token: tok("b", 160), env: "development", kind: "liveActivity" }],
        payload: { "content-state": { level: 0.42 } },
      },
      T0,
    );
    expect(r.liveActivity).toEqual({ contentState: { level: 0.42 }, event: "update", priority: 5 });
  });

  it.each([
    ["not an object", [], "body_not_object"],
    ["no tokens", {}, "tokens_missing"],
    ["empty tokens", { tokens: [] }, "tokens_missing"],
    ["nine tokens", { tokens: Array.from({ length: 9 }, (_, i) => ({ token: tok(String(i)), env: "production", kind: "widget" })) }, "too_many_tokens"],
    ["unknown top-level field", { tokens: [{ token: tok(), env: "production", kind: "widget" }], extra: 1 }, "unknown_field"],
    ["non-hex token", { tokens: [{ token: "zz".repeat(32), env: "production", kind: "widget" }] }, "token_invalid"],
    ["odd-length token", { tokens: [{ token: tok("a", 65), env: "production", kind: "widget" }] }, "token_invalid"],
    ["short token", { tokens: [{ token: tok("a", 30), env: "production", kind: "widget" }] }, "token_invalid"],
    ["huge token", { tokens: [{ token: tok("a", 514), env: "production", kind: "widget" }] }, "token_invalid"],
    ["bad env", { tokens: [{ token: tok(), env: "sandbox", kind: "widget" }] }, "env_invalid"],
    ["bad kind", { tokens: [{ token: tok(), env: "production", kind: "alert" }] }, "kind_invalid"],
    ["duplicate", { tokens: [{ token: tok(), env: "production", kind: "widget" }, { token: tok("A"), env: "production", kind: "widget" }] }, "duplicate_token"],
    ["LA without payload", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }] }, "payload_missing"],
    ["LA without content-state", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }], payload: {} }, "content_state_missing"],
    ["alert smuggled in payload", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }], payload: { "content-state": {}, alert: "hi" } }, "payload_unknown_field"],
    ["event start", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }], payload: { "content-state": {}, event: "start" } }, "event_invalid"],
    ["priority 1", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }], payload: { "content-state": {}, priority: 1 } }, "priority_invalid"],
    ["future timestamp", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }], payload: { "content-state": {}, timestamp: T0 + 301 } }, "timestamp_out_of_range"],
    ["dismissal without end", { tokens: [{ token: tok(), env: "production", kind: "liveActivity" }], payload: { "content-state": {}, "dismissal-date": T0 } }, "dismissal_date_needs_end"],
  ])("rejects %s", (_name, body, expected) => {
    expect(code(() => parsePushRequest(body, T0))).toBe(expected);
  });

  it("ignores payload for widget-only requests", () => {
    const r = parsePushRequest(
      { tokens: [{ token: tok(), env: "production", kind: "widget" }], payload: { anything: true } },
      T0,
    );
    expect(r.liveActivity).toBeUndefined();
  });
});

describe("APNs bodies", () => {
  it("widget body is exactly content-changed", () => {
    expect(JSON.parse(WIDGET_APNS_BODY)).toEqual({ aps: { "content-changed": true } });
  });

  it("Live Activity body carries timestamp, event, content-state and dates, never an alert", () => {
    const body = JSON.parse(
      liveActivityApnsBody(
        { contentState: { l: 1 }, event: "end", priority: 10, staleDate: T0 + 60, dismissalDate: T0 + 120 },
        T0,
      ),
    );
    expect(body).toEqual({
      aps: { timestamp: T0, event: "end", "content-state": { l: 1 }, "stale-date": T0 + 60, "dismissal-date": T0 + 120 },
    });
    expect(body.aps.alert).toBeUndefined();
  });

  it("rejects a payload over 4 KB", () => {
    expect(
      code(() => liveActivityApnsBody({ contentState: { x: "y".repeat(4100) }, event: "update", priority: 5 }, T0)),
    ).toBe("payload_too_large");
  });
});
