---
id: PUSH-001
title: Push-driven widget updates and the push relay
milestone: free-team   # owner decision U: built now, runs only after enrollment
status: Draft
depends_on: [NET-001, NET-002, NET-003, NET-004, UI-003]
adrs: [17, 19, 20, 21, 22, 23]
targets: [Shared, Levels-Mac, Levels-iOS, Widgets-iOS, relay]
---

# PUSH-001: Push-driven widget updates and the push relay

## Why

The iPhone widget can only refresh every 15–60 minutes on its own, so it shows old levels. The Mac knows first when something changes. With a push the Mac can ask the iPhone widget to reload soon after a real change, and a Live Activity can show a charging device's level almost live. ADR-0023 has the research, the freshness we can honestly expect, and the threat model.

## Scope

- In: the relay in `relay/` (Cloudflare Worker, done on branch `feature/push-relay`); its API; the iPhone side (widget push token, App Attest, grants, handing tokens to the Mac); the hub route that carries them; the Mac's push policy and client; the "Follow charging" Live Activity; owner setup after enrollment.
- Out (and where it goes instead): CloudKit silent pushes → SYNC-001. Alerts → ALR-001. Away-from-home data for the widget → open question 2. Mac widgets → they reload locally (lead's call 17). Watch complications by push → later.

## Behaviour

### Relay: general

- **R1** The relay accepts only `POST` with `content-type: application/json` and a body of at most 8 KB. Other methods get 405, a wrong content type or a larger body 400, an unknown path 404.
- **R2** Every response has `content-type: application/json` and `cache-control: no-store`. Errors are `{"error":"<code>"}`.
- **R3** The relay never logs a request, token, grant or payload, and never stores a raw token. Workers observability stays off (`wrangler.toml`).
- **R4** The relay only sends APNs push types `widgets` and `liveactivity`, with topics `<IOS_BUNDLE_ID>.push-type.widgets` and `<IOS_BUNDLE_ID>.push-type.liveactivity`. It never sends an `alert`, never `event: start`.

### Relay: `POST /v1/widget-push` (Mac)

- **R10** Body:

  ```json
  {
    "tokens": [
      { "token": "<hex>", "env": "development" | "production", "kind": "widget" | "liveActivity" }
    ],
    "payload": { ...only for liveActivity... }
  }
  ```

  - `tokens`: 1–8 entries. `token` is hex (either case), even length, 32–512 characters; the relay lowercases it. The same `kind` + token twice is a 400. No other fields.
  - `payload` is ignored when every token is `widget` (the Mac may send `{"aps":{"content-changed":true}}`; the relay builds that body itself).
  - With any `liveActivity` token, `payload` is required and may hold only: `content-state` (object, required), `event` (`"update"` default, or `"end"`), `timestamp` (Unix seconds; default now; no more than 5 min ahead or 1 h behind), `stale-date`, `dismissal-date` (only with `end`), `priority` (`5` default, or `10`). The same payload goes to every Live Activity token in the request.
- **R11** APNs bodies: widget `{"aps":{"content-changed":true}}`; Live Activity `{"aps":{"timestamp","event","content-state","stale-date"?,"dismissal-date"?}}`, at most 4096 bytes (else 400 `payload_too_large`).
- **R12** Headers to APNs: `authorization: bearer <JWT>`, `apns-push-type`, `apns-topic`, `apns-id` (random UUID), `apns-expiration` = now + 3600. `apns-priority` only for Live Activities (5 or 10); none for widgets (Apple's sample sets none).
- **R13** `env: "development"` goes to `https://api.sandbox.push.apple.com/3/device/<token>` with the sandbox key; `"production"` to `https://api.push.apple.com/3/device/<token>` with the production key. A missing key gives that token `failed`.
- **R14** Order of checks: auth (401) → body (400) → every token covered by a grant for the same `kind` and `env` (else 401 `token_not_granted`) → rate limits (429) → send.
- **R15** Responses:

  | Status | When | Body |
  |---|---|---|
  | 202 | At least one token wasn't invalid or rate-limited. | `{"results":[{"index":0,"status":"sent"}, …], "invalidTokens":["<hex>", …]}`. `invalidTokens` (lowercase) is present only when not empty. |
  | 400 | Bad body (after auth). | `{"error":"<code>"}` |
  | 401 | Auth failed. | `{"error":"<code>"}` |
  | 410 | Every token was invalid (`unregistered` or `bad_token`). | `{"error":"tokens_invalid","results":[…],"invalidTokens":[…]}` |
  | 429 | The granting iPhone's limit is hit, or every token is rate-limited. | `{"error":"rate_limited"}`, header `Retry-After: <seconds>` |
  | 500 | Relay misconfigured or internal error. | `{"error":"<code>"}` |

  `results[].index` is the position in `tokens`. `status` is one of `sent`, `unregistered` (APNs 410), `bad_token` (APNs 400 `BadDeviceToken` / `DeviceTokenNotForTopic`), `rate_limited`, `throttled_by_apns` (APNs 429), `failed` (anything else; retry later).
- **R16** The Mac drops every token in `invalidTokens` (202 or 410) and asks that iPhone for new ones over the hub (R72). `failed` and `throttled_by_apns` are not retried before the next change.

### Mac request authentication (exact headers)

- **R17** Every `/v1/widget-push` request carries three headers:

  | Header | Value |
  |---|---|
  | `Levels-Grant` | One or more grants (`g1.…`) from the iPhones whose tokens are in the body, joined with `,` (spaces allowed). At most 4. All must name the same Mac key. |
  | `Levels-Timestamp` | Current Unix time in whole seconds, decimal (`1764000000`). Must be within ±300 s of the relay's clock. |
  | `Levels-Signature` | base64url (no padding) of the 64-byte raw ECDSA P-256 signature (`r‖s`, CryptoKit `P256.Signing.ECDSASignature.rawRepresentation`) over the UTF-8 bytes of the signing string below, signed with SHA-256 (CryptoKit `signature(for:)` does this). |

  Signing string, four `\n` (0x0A) separators, no trailing newline:

  ```
  levels-push-v1
  <Levels-Timestamp value>
  POST
  /v1/widget-push
  <lowercase hex SHA-256 of the exact body bytes sent>
  ```

- **R18** The Mac's push key is a P-256 signing key made on first use and kept in the Mac's Keychain (Secure Enclave `SecureEnclave.P256.Signing.PrivateKey` when available, else a software `P256.Signing.PrivateKey`; **Builder's call** which). Its public key travels as base64url (no padding) of `x963Representation` (65 bytes, `0x04‖X‖Y`). "Remove all pairings" makes a new key.
- **R19** 401 codes: `auth_missing`, `timestamp_invalid`, `timestamp_skew`, `grant_count`, `grant_invalid`, `grant_expired`, `grant_mac_mismatch`, `signature_invalid`, `token_not_granted`. On `grant_expired` or `token_not_granted` the Mac asks the iPhone for a fresh grant (R72); on `timestamp_skew` it logs locally and retries once at the next change; on the others it stops pushing to that iPhone until a new grant arrives.

Swift shape (**Builder's call** beyond this):

```swift
public protocol PushRelayAuth: Sendable {
    /// Returns the three Levels-* headers for this exact body.
    func headers(for body: Data, path: String, at date: Date) throws -> [String: String]
}
```

### Relay: iPhone routes

- **R30** `POST /v1/challenge`, body `{}` → `200 {"challenge":"ch1.…","expiresAt":<unix>}`. Valid 5 minutes. Use each challenge once.
- **R31** `POST /v1/attest`, body `{"keyId":"<base64 from generateKey>","attestation":"<base64 attestation object>","challenge":"<challenge>"}`. The app calls `attestKey(keyId, clientDataHash: SHA256(UTF-8 challenge string))`. → `200 {"credential":"c1.…","env":"production"|"development","expiresAt":<unix>}`. The credential lasts 1 year; the app keeps it with the key ID in its Keychain.
- **R32** The relay checks the attestation as Apple's server guide says: chain to the Apple App Attestation Root CA, nonce extension `1.2.840.113635.100.8.2`, SHA-256 of the key equals `keyId`, RP ID = SHA-256 of `<APPLE_TEAM_ID>.<IOS_BUNDLE_ID>`, counter 0, `aaguid` (`appattestdevelop` → `development`, `appattest`+7×0x00 → `production`), credential ID = key ID, and `apple_validation_category_01` ∈ {2 TestFlight, 3 development, 4 App Store} when present.
- **R33** Token hash, computed the same on the iPhone and the relay: base64url (no padding) of the first 16 bytes of SHA-256 of the UTF-8 string `"levels-token-v1:" + <lowercase hex token>`. 22 characters.
- **R34** `POST /v1/grant`, body `{"credential":"c1.…","clientData":"<base64 of the exact JSON bytes>","assertion":"<base64 assertion>"}`. `clientData` JSON: `{"challenge":"<fresh challenge>","macKey":"<Mac public key, R18 format>","tokens":[{"kind":"widget"|"liveActivity","hash":"<R33>"}]}` (1–4 tokens). The app calls `generateAssertion(keyId, clientDataHash: SHA256(clientData bytes))`. → `200 {"grant":"g1.…","env":"…","expiresAt":<unix>}`, valid 30 days. The grant's environment is the credential's.
- **R35** Errors on iPhone routes: 400 for missing or malformed fields; 401 `challenge_invalid`, `challenge_expired`, `credential_invalid`, `credential_expired`, `attest_<reason>`; 429 with `Retry-After`.
- **R36** A Debug build (App Attest development, APNs development) gets development grants and can only push to sandbox tokens. TestFlight and App Store builds get production grants.

### Rate limits

- **R40** Per widget token: 12 per hour and 100 per 24 h.
- **R41** Per Live Activity token: 120 per hour and 1000 per 24 h; priority 10 also at most 12 per hour.
- **R42** Per granting iPhone (grant `dev`): 400 tokens per hour across all requests; over it the whole request gets 429.
- **R43** Grants: 30 per hour per iPhone. Challenge, attest and grant: 60 per hour per client IP (counted under a keyed hash of the IP).
- **R44** Counters live in one Durable Object per key, keyed by token hash or device ID, and delete themselves 25 hours after the last allowed hit.

### Mac: when to push (owner of `Levels-Mac`)

- **R50** The Mac pushes `widget` tokens only when what a widget shows changes (lead's call 17 list: device set, level, charging, plugged in, Low Power Mode, names, hidden set) for a device other than that iPhone itself.
- **R51** At most one widget push per iPhone per 15 minutes, coalescing changes inside the gap into one push at its end.
- **R52** Exceptions that skip R51 but still count toward R53: a shown device is plugged in or unplugged, or crosses its low-battery threshold (ALR-001).
- **R53** At most 48 widget pushes per iPhone per day (local midnight to midnight). After that, none until the next day.
- **R54** No widget push while that iPhone is talking to the Mac with the app in the foreground (its long-poll is open, ADR-0020 Decision 5): the app reloads its widgets itself, unbudgeted.
- **R55** A Live Activity token gets an update on every change of its device's level (whole percent) or charging state, priority 5, at most one per 60 s; priority 10 only for "full", "unplugged" and the final `end`. `stale-date` = now + 30 min on every update.
- **R56** Pushing is on only when the paid build has a relay URL configured and the iPhone sent a grant; otherwise nothing is sent and nothing changes for the user.

### iPhone (owner of `Levels-iOS`, `Widgets-iOS`)

- **R70** Each push-enabled widget configuration adds `.pushHandler(LevelsWidgetPushHandler.self)`. The handler writes the token (hex) and its environment to the App Group; it makes no network calls (App Attest doesn't work in widget extensions). The app also reads `WidgetCenter.shared.currentPushInfo` on launch in case the handler was missed.
- **R71** The app does App Attest once per install (R30–R31). If `isSupported` is false (simulator), push stays off.
- **R72** When its widget token, a Live Activity token, the Mac key, or a grant within 7 days of expiry changes, and the app runs (foreground or background refresh), it gets a grant (R34) and sends `PUT /v1/push-registration` to the Mac over the hub: `{"tokens":[{"token":"<hex>","env":"…","kind":"…"}],"grant":"g1.…","expiresAt":<unix>}`. The Mac answers its public push key on `GET /v1/push-key` → `{"macKey":"<R18>"}`. Both are new NET-001 routes, authenticated like the others.
- **R73** The widget's timeline provider, on each reload, fetches from the Mac (NET-004 variant B) unless the App Group cache is under 60 s old. It can't tell a push-triggered reload from another (Apple gives no signal), so this applies to every reload.
- **R74** "Follow charging": a button on a device row (Mac or accessory, charging or below its threshold) starts a Live Activity with `pushType: .token`. Static attributes hold the device name and kind; `ContentState` holds only `level` (Int, 0–100), `isCharging` (Bool), `updatedAt` (Unix seconds); default JSON coding (Apple requires it). Its token goes to the Mac per R72. It ends at 100 %, at unplug (Mac sends `end`), or after 8 hours. One at a time.
- **R75** Live Activity is a Levels Pro feature (ADR-0021); widget push follows the widget's own tier. See open question 1.

### Owner setup after paying (one time)

- **R80** Apple Developer account: enable Push Notifications and App Attest on the iOS App ID; create two APNs keys in Keys (one Sandbox, one Production; or one team key for both); download each `.p8` once and note its Key ID; note the Team ID.
- **R81** Cloudflare: create a free account with 2FA; in `relay/`, run `npx wrangler login`; set `IOS_BUNDLE_ID`, `APPLE_TEAM_ID`, `APNS_KEY_ID_SANDBOX`, `APNS_KEY_ID_PRODUCTION` in `wrangler.toml`; run `npx wrangler secret put APNS_KEY_SANDBOX` (paste the `.p8` contents), the same for `APNS_KEY_PRODUCTION`, and `npx wrangler secret put RELAY_HMAC_KEY` with the output of `openssl rand -base64 32`; then `npx wrangler deploy`. Delete the `.p8` files from Downloads after storing them in a password manager.
- **R82** Put the relay URL (`https://levels-push-relay.<account>.workers.dev`, or a custom domain) in the app builds' config. Rotate `RELAY_HMAC_KEY` by moving the old value to `RELAY_HMAC_KEY_PREVIOUS` first; drop it after 30 days.

## Design

- Relay code: `relay/src/` — `index.ts` (routes), `apns.ts` (JWT cache, transport, routing), `auth.ts` (R17–R19), `signed.ts` (challenges, credentials, grants, R33), `appattest.ts` (R32, assertions), `cbor.ts`, `validate.ts` (R10–R11), `ratelimit.ts` (R40–R44, Durable Object). Tests in `relay/test/` (`npm test`).
- Grants and credentials: `<prefix>.<base64url JSON>.<base64url HMAC-SHA256(RELAY_HMAC_KEY, prefix + "." + JSON part)>`. Grant JSON `{v:1, env, mac, dev, t:[[kind, hash]…], iat, exp}`. The Mac treats them as opaque strings.
- The APNs transport is a function `(url, init) => Promise<Response>`; `fetch` on Workers. If Workers can't do HTTP/2 to APNs (ADR-0023 Assumption), a small Node `http2` host implements the same function.
- **Builder's call:** where the Mac's `PushRelayClient` lives (Shared `LevelsNet` or the Mac target), retry timing, and how push state shows in Mac Settings ▸ iPhone ("Widget updates: on").

## Edge cases and failure modes

- Mac asleep or offline: nothing is sent; widget falls back to its timeline; Live Activity goes stale at `stale-date`.
- iPhone away from home: widget pushes arrive but its fetch fails; it shows the cache with its age (ADR-0017). Live Activity still updates.
- Token rotates: `invalidTokens` → R16 → R72.
- Grant expires while the iPhone app isn't opened for 30 days: pushes get 401 `grant_expired`; the Mac stops until the app runs again. Background refresh renews grants 7 days early.
- Clock skew on the Mac over 5 min: 401 `timestamp_skew`.
- Debug build pushing to a production token: 401 `token_not_granted` (grant env mismatch).
- App reinstall: App Attest key is gone; the app attests again.
- Relay down: pushes fail; nothing else in Levels depends on the relay.
- iOS drops a push it accepted (reported on iOS 26): the widget catches up on its next timeline reload.

## Acceptance criteria

Relay (automated, done):

- [x] AC1 — Given a valid grant and signature, when the Mac posts one widget token, then the relay returns 202 `{"results":[{"index":0,"status":"sent"}]}` and APNs receives `{"aps":{"content-changed":true}}` with `apns-push-type: widgets` and topic `<bundle>.push-type.widgets`.
- [x] AC2 — `development` tokens go to the sandbox host with the sandbox key; `production` to the production host with the production key.
- [x] AC3 — The provider JWT is ES256 with `kid`, `iss`, `iat`, verifies with the key's public half, is reused for 50 min and re-signed after; an `ExpiredProviderToken` 403 triggers one retry with a new JWT.
- [x] AC4 — Missing headers, a forged or expired grant, a signature from another key, a changed body, a timestamp off by more than 300 s, a token not in the grant (or another kind or env), and grants for two Macs each give 401 with the R19 code and no APNs call.
- [x] AC5 — Every R10 violation gives 400 with its code, after auth.
- [x] AC6 — The 13th widget push to one token within an hour gives 429 with `Retry-After`; a limited token next to a good one gives 202 with `rate_limited` for that index; priority-10 Live Activity pushes are limited separately; an iPhone over 400/hour gets 429 for the whole request.
- [x] AC7 — APNs 410 or `BadDeviceToken` for every token gives 410 with `invalidTokens`; for some tokens gives 202 with `invalidTokens`.
- [x] AC8 — A valid App Attest attestation gives a credential; a wrong chain, nonce, RP ID, counter, aaguid, credential ID or validation category gives 401; an assertion with a bad signature, other client data, another RP ID or counter 0 gives 401.
- [x] AC9 — challenge → attest → grant → widget-push works end to end; an expired challenge gives 401.
- [x] AC10 — Challenge requests over 60/hour from one IP give 429.
- [x] AC11 — A Live Activity payload with `alert`, `event: start` or over 4 KB is rejected.

After enrollment (manual):

- [ ] AC12 — From the deployed Worker, a widget push to the owner's Debug iPhone returns `sent` (proves HTTP/2 from Workers) and the widget reloads within 1 minute with WidgetKit developer mode on.
- [ ] AC13 — With developer mode off, over 3 days on the home Wi-Fi, the median delay from a Mac-side change to the iPhone widget showing it is under 5 minutes while the Mac sent ≤ 48 pushes a day. Record how many pushes produced no reload.
- [ ] AC14 — "Follow charging" on AirPods: the Live Activity shows each whole-percent change within 2 minutes and ends at 100 %.
- [ ] AC15 — `wrangler tail` during AC12 shows no token, grant or payload.

Apple side (owned by the Swift work, `feature/push-widget-client`):

- [ ] AC20 — Given a Mac push key and body, `PushRelayAuth.headers` yields a signature the relay accepts (shared test vector from `relay/test/helpers.ts` `signingString`).
- [ ] AC21 — R50–R55: with a fake clock, a run of level changes produces at most one push per 15 min and 48 per day; plug/unplug skips the gap.
- [ ] AC22 — R16: `invalidTokens` removes those tokens and triggers R72.

## Tests

AC1–AC11 are `vitest` tests in `relay/test/` (`npm test`, 89 tests, Node environment with WebCrypto; the App Attest tests use a generated stand-in root CA because Apple's can't sign test data). AC20–AC22 are Swift Testing unit tests. AC12–AC15 need the paid account and real devices.

## Open questions

1. Is widget push for everyone, or only Levels Pro? It costs a few relay requests per user per day. Recommended: everyone for the free small widget too (it's the widget that looks stale), Live Activity Pro only.
2. Away from home the widget push helps nothing until iCloud. Should the relay later hold an end-to-end-encrypted snapshot for the widget (ADR-0023 Option E)? Recommended: no; wait for SYNC-001.
