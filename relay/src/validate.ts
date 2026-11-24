// Validation of POST /v1/widget-push bodies (PUSH-001 R10–R16) and the APNs
// payloads built from them. The relay never adds an `alert`, never starts a
// Live Activity and never sends any other push type.

import type { ApnsEnvironment, PushKind } from "./apns.js";

export const MAX_BODY_BYTES = 8 * 1024;
export const MAX_TOKENS = 8;
export const MAX_APNS_PAYLOAD_BYTES = 4096;
/** Apple: "Don't make assumptions about device token size." Bounds are generous. */
export const MIN_TOKEN_HEX = 32;
export const MAX_TOKEN_HEX = 512;

export interface PushTarget {
  token: string; // lowercase hex
  env: ApnsEnvironment;
  kind: PushKind;
}

export interface LiveActivityPayload {
  contentState: Record<string, unknown>;
  event: "update" | "end";
  timestamp?: number;
  staleDate?: number;
  dismissalDate?: number;
  priority: 5 | 10;
}

export interface PushRequest {
  targets: PushTarget[];
  liveActivity?: LiveActivityPayload;
}

export class BadRequest extends Error {
  constructor(public readonly code: string) {
    super(code);
  }
}

const PAYLOAD_KEYS = new Set([
  "content-state",
  "event",
  "timestamp",
  "stale-date",
  "dismissal-date",
  "priority",
]);

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isUnixSeconds(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v >= 0 && v < 1e11;
}

export function parsePushRequest(raw: unknown, now: number): PushRequest {
  if (!isObject(raw)) throw new BadRequest("body_not_object");
  for (const k of Object.keys(raw)) {
    if (k !== "tokens" && k !== "payload") throw new BadRequest("unknown_field");
  }
  const tokens = raw.tokens;
  if (!Array.isArray(tokens) || tokens.length === 0) throw new BadRequest("tokens_missing");
  if (tokens.length > MAX_TOKENS) throw new BadRequest("too_many_tokens");

  const seen = new Set<string>();
  const targets: PushTarget[] = tokens.map((t) => {
    if (!isObject(t)) throw new BadRequest("token_not_object");
    for (const k of Object.keys(t)) {
      if (k !== "token" && k !== "env" && k !== "kind") throw new BadRequest("unknown_field");
    }
    const { token, env, kind } = t;
    if (typeof token !== "string") throw new BadRequest("token_invalid");
    if (
      token.length < MIN_TOKEN_HEX ||
      token.length > MAX_TOKEN_HEX ||
      token.length % 2 !== 0 ||
      !/^[0-9a-fA-F]+$/.test(token)
    ) {
      throw new BadRequest("token_invalid");
    }
    if (env !== "development" && env !== "production") throw new BadRequest("env_invalid");
    if (kind !== "widget" && kind !== "liveActivity") throw new BadRequest("kind_invalid");
    const hex = token.toLowerCase();
    const dedupeKey = `${kind}:${hex}`;
    if (seen.has(dedupeKey)) throw new BadRequest("duplicate_token");
    seen.add(dedupeKey);
    return { token: hex, env, kind };
  });

  const needsPayload = targets.some((t) => t.kind === "liveActivity");
  const payload = raw.payload;
  let liveActivity: LiveActivityPayload | undefined;
  if (payload !== undefined && payload !== null) {
    if (!isObject(payload)) throw new BadRequest("payload_not_object");
    if (needsPayload) liveActivity = parseLiveActivityPayload(payload, now);
    // Widget-only requests ignore `payload`: a widget push carries no data.
  }
  if (needsPayload && !liveActivity) throw new BadRequest("payload_missing");
  return { targets, liveActivity };
}

function parseLiveActivityPayload(p: Record<string, unknown>, now: number): LiveActivityPayload {
  for (const k of Object.keys(p)) if (!PAYLOAD_KEYS.has(k)) throw new BadRequest("payload_unknown_field");
  const contentState = p["content-state"];
  if (!isObject(contentState)) throw new BadRequest("content_state_missing");
  const event = p.event ?? "update";
  if (event !== "update" && event !== "end") throw new BadRequest("event_invalid");
  const priority = p.priority ?? 5;
  if (priority !== 5 && priority !== 10) throw new BadRequest("priority_invalid");

  const out: LiveActivityPayload = { contentState, event, priority };
  if (p.timestamp !== undefined) {
    if (!isUnixSeconds(p.timestamp)) throw new BadRequest("timestamp_invalid");
    // A reading may be up to an hour old; never more than 5 min in the future.
    if (p.timestamp > now + 300 || p.timestamp < now - 3600) throw new BadRequest("timestamp_out_of_range");
    out.timestamp = p.timestamp;
  }
  if (p["stale-date"] !== undefined) {
    if (!isUnixSeconds(p["stale-date"])) throw new BadRequest("stale_date_invalid");
    out.staleDate = p["stale-date"];
  }
  if (p["dismissal-date"] !== undefined) {
    if (!isUnixSeconds(p["dismissal-date"])) throw new BadRequest("dismissal_date_invalid");
    if (event !== "end") throw new BadRequest("dismissal_date_needs_end");
    out.dismissalDate = p["dismissal-date"];
  }
  return out;
}

/** The fixed widget payload from Apple's WidgetKit push documentation. */
export const WIDGET_APNS_BODY = JSON.stringify({ aps: { "content-changed": true } });

export function liveActivityApnsBody(p: LiveActivityPayload, now: number): string {
  const aps: Record<string, unknown> = {
    timestamp: p.timestamp ?? now,
    event: p.event,
    "content-state": p.contentState,
  };
  if (p.staleDate !== undefined) aps["stale-date"] = p.staleDate;
  if (p.dismissalDate !== undefined) aps["dismissal-date"] = p.dismissalDate;
  const body = JSON.stringify({ aps });
  if (new TextEncoder().encode(body).length > MAX_APNS_PAYLOAD_BYTES) {
    throw new BadRequest("payload_too_large");
  }
  return body;
}
