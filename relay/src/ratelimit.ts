// Rate limits (PUSH-001 R40–R44). Fixed windows per key, kept in one Durable
// Object per key so counts are exact across Cloudflare locations. Keys are
// token hashes and device IDs, never raw tokens. State deletes itself after
// the longest window passes with no traffic.

export interface Window {
  /** Window length in seconds. */
  w: number;
  /** Maximum hits per window. */
  max: number;
}

export interface LimitDecision {
  allowed: boolean;
  /** Seconds until the blocking window resets; 0 when allowed. */
  retryAfter: number;
}

type WindowState = { start: number; count: number };
export type LimiterState = Record<string, WindowState>;

/** Pure fixed-window check-and-increment. Mutates `state` only when allowed. */
export function applyHit(state: LimiterState, now: number, limits: Window[], cost: number): LimitDecision {
  let retryAfter = 0;
  for (const l of limits) {
    const s = state[String(l.w)];
    const fresh = !s || now >= s.start + l.w || now < s.start;
    const count = fresh ? 0 : s.count;
    if (count + cost > l.max) {
      retryAfter = Math.max(retryAfter, fresh ? l.w : s!.start + l.w - now);
    }
  }
  if (retryAfter > 0) return { allowed: false, retryAfter };
  for (const l of limits) {
    const key = String(l.w);
    const s = state[key];
    if (!s || now >= s.start + l.w || now < s.start) state[key] = { start: now, count: cost };
    else s.count += cost;
  }
  return { allowed: true, retryAfter: 0 };
}

/** Default ceilings. The Mac's own policy (PUSH-001 R50–R55) stays well below them. */
export const LIMITS = {
  widgetToken: [
    { w: 3600, max: 12 },
    { w: 86400, max: 100 },
  ],
  liveActivityToken: [
    { w: 3600, max: 120 },
    { w: 86400, max: 1000 },
  ],
  liveActivityHighPriority: [{ w: 3600, max: 12 }],
  device: [{ w: 3600, max: 400 }],
} satisfies Record<string, Window[]>;

export interface RateLimiter {
  hit(key: string, limits: Window[], cost?: number): Promise<LimitDecision>;
}

/** Talks to the RateLimiterObject Durable Object named after the key. */
export class DurableRateLimiter implements RateLimiter {
  constructor(private readonly ns: DurableObjectNamespace) {}

  async hit(key: string, limits: Window[], cost = 1): Promise<LimitDecision> {
    const stub = this.ns.get(this.ns.idFromName(key));
    const res = await stub.fetch("https://limiter/hit", {
      method: "POST",
      body: JSON.stringify({ limits, cost }),
    });
    if (!res.ok) throw new Error(`limiter ${res.status}`);
    return (await res.json()) as LimitDecision;
  }
}

/** In-memory limiter for tests and local runs. */
export class MemoryRateLimiter implements RateLimiter {
  readonly states = new Map<string, LimiterState>();
  constructor(private readonly now: () => number) {}

  async hit(key: string, limits: Window[], cost = 1): Promise<LimitDecision> {
    let s = this.states.get(key);
    if (!s) {
      s = {};
      this.states.set(key, s);
    }
    return applyHit(s, this.now(), limits, cost);
  }
}

interface MinimalStorage {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown): Promise<void>;
  deleteAll(): Promise<void>;
  setAlarm(time: number): Promise<void>;
}

/** Durable Object class. Uses the fetch interface so it needs no runtime-only imports. */
export class RateLimiterObject {
  constructor(
    private readonly state: { storage: MinimalStorage },
    _env?: unknown,
    private readonly now: () => number = () => Math.floor(Date.now() / 1000),
  ) {}

  async fetch(request: Request): Promise<Response> {
    let body: { limits?: Window[]; cost?: number };
    try {
      body = (await request.json()) as typeof body;
    } catch {
      return new Response("bad request", { status: 400 });
    }
    const limits = body.limits;
    const cost = body.cost ?? 1;
    if (
      !Array.isArray(limits) ||
      limits.length === 0 ||
      limits.length > 4 ||
      !limits.every((l) => Number.isInteger(l.w) && l.w > 0 && l.w <= 86400 && Number.isInteger(l.max) && l.max > 0) ||
      !Number.isInteger(cost) ||
      cost < 1
    ) {
      return new Response("bad request", { status: 400 });
    }
    const now = this.now();
    const s = (await this.state.storage.get<LimiterState>("s")) ?? {};
    const decision = applyHit(s, now, limits, cost);
    if (decision.allowed) {
      await this.state.storage.put("s", s);
      const longest = Math.max(...limits.map((l) => l.w));
      await this.state.storage.setAlarm((now + longest + 60) * 1000);
    }
    return Response.json(decision);
  }

  /** Runs after the longest window with no allowed hit: forget the key. */
  async alarm(): Promise<void> {
    await this.state.storage.deleteAll();
  }
}
