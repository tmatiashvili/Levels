# ADR-0023: Push-driven widget updates through a small relay that holds the APNs key

- **Status:** Proposed
- **Date:** 2026-11-24
- **Deciders:** project owner
- **Related:** ADR-0017, ADR-0019, ADR-0020, ADR-0021, ADR-0022, PUSH-001, NET-001, NET-004

## Context

The iPhone widget shows old levels. In hub mode (ADR-0020) the widget gets new data only when WidgetKit reloads it, and WidgetKit spreads reloads over the day. Owner decision U (2026-11-24): build push-driven widget updates now and pay the $99 Apple Developer Program fee later. Nothing here can run on a device until then: push needs the paid account (ADR-0022).

The Mac is the hub. It sees changes first (its own battery, its accessories, the iPhone's own reports), so the Mac decides when to push. The Mac app is a public Developer ID download (owner decision Q), so anything inside it can be extracted. The APNs signing key must never ship in it.

### Facts (from Apple documentation)

WidgetKit push (iOS 26, iPadOS 26, macOS 26, watchOS 26, visionOS 26):

- The widget registers a `WidgetPushHandler` with `.pushHandler(_:)`; `pushTokenDidChange(_:widgets:)` delivers the token. The User Notifications framework can't register a widget. ([Updating widgets with WidgetKit push notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications), [WidgetPushHandler](https://developer.apple.com/documentation/widgetkit/widgetpushhandler))
- Request: `apns-push-type: widgets`, `apns-topic: <bundle ID>.push-type.widgets`, body `{"aps":{"content-changed":true}}`. On receipt "it reloads your timelines, similar to when you call `reloadAllTimelines()`". The payload carries no data. Broadcast (channel) pushes can't update widgets. (same page)
- "Like timeline updates, the system budgets WidgetKit push notifications and delivers them opportunistically, making push updates an additional update mechanism for your widgets that doesn't replace timeline updates." (same page) WWDC25 "What's new in widgets": "Try to keep your update pushes limited, such as by throttling updates on your server." WidgetKit developer mode in Settings ignores push and reload budgets for testing. ([WWDC25 session 278](https://developer.apple.com/videos/play/wwdc2025/278/))
- The general reload budget: "For a widget the user frequently views, a daily budget typically includes from 40 to 70 refreshes. This rate roughly translates to widget reloads every 15 to 60 minutes." Reloads don't count while the app is in the foreground. Entries should be at least about 5 minutes apart. ([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date))
- Apple doesn't say whether widget pushes share the 40–70 budget with timeline reloads or have their own. A developer reports iOS 26 pushes that APNs accepted (HTTP 200) but that never reloaded the widget ([forum thread 839182](https://developer.apple.com/forums/thread/839182)). The widget can't tell that a reload came from a push ([forum thread 795627](https://developer.apple.com/forums/thread/795627)).

Live Activities with push updates:

- `apns-push-type: liveactivity`, `apns-topic: <bundle ID>.push-type.liveactivity`, `apns-priority` 5 or 10. The `aps` dictionary holds `timestamp`, `event` (`update` / `end`), `content-state` (decoded with default JSON strategies), optional `stale-date` and `dismissal-date`. ([Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications))
- "The system allows for a certain budget of ActivityKit push notifications per hour." Priority 10 counts toward it and may be throttled; priority 5 "doesn't count toward the budget". `NSSupportsLiveActivitiesFrequentUpdates` raises the limit; people can turn frequent updates off in Settings (`frequentPushesEnabled`). (same page)
- Starting by push (push-to-start) needs an `alert` in the payload. (same page)
- A Live Activity is active for at most 8 hours, then stays on the Lock Screen up to 4 more hours. Static plus dynamic data can't exceed 4 KB. A Live Activity can't use the network. It appears on the Lock Screen, Dynamic Island, StandBy, a paired Apple Watch, CarPlay and the Mac menu bar. Apps start one from the foreground (or a `LiveActivityIntent`). ([Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities))

APNs:

- HTTP/2 and TLS 1.2+ to `api.sandbox.push.apple.com` (development) or `api.push.apple.com` (production). Payload limit 4 KB. `apns-priority` defaults to 10. 410 means the token is no longer valid; 400 `BadDeviceToken` often means the wrong environment. "Don't make assumptions about device token size." ([Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns))
- Provider JWT: ES256, header `alg`, `kid`; claims `iss` (Team ID), `iat`. "Refresh your token no more than once every 20 minutes and no less than once every 60 minutes." Apple recommends separate sandbox and production keys. ([Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns))

App Attest:

- `DCAppAttestService` on iOS 14+: a Secure Enclave key, certified by Apple, then assertions signed with it. Most app extensions can't use it (`generateKey` fails), so the widget extension can't; the iOS app can. ([isSupported](https://developer.apple.com/documentation/devicecheck/dcappattestservice/issupported), [Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity))
- On the Mac, the reference page still says `isSupported` is always false. Apple engineers on the forums say macOS 27 supports App Attest in full Mac apps in a user context only ([thread 836329](https://developer.apple.com/forums/thread/836329), [thread 831492](https://developer.apple.com/forums/thread/831492)); the server guide now lists a Developer ID validation category and a macOS-only access-policy check ([Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)). Levels supports macOS 26 (ADR-0002), so the Mac can't rely on it.

Assumptions:

- **Assumption:** Cloudflare Workers' outbound `fetch` reaches APNs over HTTP/2. A community APNs client for Workers (`@fivesheepco/cloudflare-apns2`) uses plain `fetch`, but Cloudflare's docs don't state the protocol. First check after enrollment (PUSH-001 AC12). If it fails, the relay's `Transport` is swapped for a tiny Node `http2` host; the rest of the code stays.
- **Assumption:** iOS 26 attestations may lack the `apple_validation_category_01` extension. The relay accepts a missing extension and checks it when present.
- **Assumption:** a push token the relay uses and forgets is not "collected" in the App Store privacy-label sense ("collect" means access "for a period longer than what is necessary to service the transmitted request in real time", [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)). Rate-limit counters keep a hash of the token for up to 25 hours.

## How fresh each option can honestly get

| | Widget push | Live Activity push |
|---|---|---|
| What arrives | "Reload now". No data. | The levels themselves (`content-state`). |
| Where the data comes from | The widget fetches from the Mac (NET-004 variant B). Same Wi-Fi only. | The push itself. Works anywhere the iPhone has internet. |
| Typical delay after the Mac sees a change | Seconds to a few minutes, while budget lasts. | Priority 10: seconds. Priority 5: seconds to minutes; may be grouped. |
| Daily ceiling | The widget budget: about 40–70 reloads for a widget the owner looks at often. Pushes don't raise it, and may share it with timeline reloads. | Priority 5 isn't budgeted; priority 10 has an hourly budget. |
| Limits | Opportunistic; some accepted pushes don't reload (reported on iOS 26). | Started by the user in the app; ends after 8 hours; only one or a few devices fit. |
| Away from home | Push arrives, but the widget can't reach the Mac: no gain. | Works while the Mac is awake and online. |
| Mac asleep | Nothing is sent. | Nothing is sent; `stale-date` marks it old. |

So: widget push makes the widget update **soon after a real change** instead of on a fixed schedule, on the home Wi-Fi, up to the daily budget. It does not make the widget real-time. A Live Activity is the only near-real-time surface, and only for a few hours at a time.

## Decision

1. **Build widget push for the iPhone widgets.** The Mac sends a widget push when what a widget shows changes (lead's call 17 rule), at most one per 15 minutes per iPhone and 48 per day, with two exceptions that skip the 15-minute gap but still count: plug-in/unplug of a shown device and a shown device crossing its alert threshold (PUSH-001 R50–R55). The widget's own timeline stays as it is (ADR-0017); push is extra.
2. **Build an optional "Follow charging" Live Activity.** *(Amended 2026-11-24 by owner decision V and LIVE-001: one "Live levels" activity for this iPhone, the Mac and AirPods instead, started from the Devices screen or Settings, updated locally by the app on the free team and by Mac pushes after enrollment; `NSSupportsLiveActivitiesFrequentUpdates` is on. The rest of this point describes the original plan.)* The user starts it from a device's row in the iPhone app for a Mac, AirPods or another accessory that is charging or low. It shows that device's level and charging state, updated by the Mac with priority-5 pushes (priority 10 only for "full", "unplugged" and the end), and ends at 100 %, at unplug, or after 8 hours. A charging session has a clear start and end, which is what Live Activities are for. No push-to-start: it needs an alert, and the relay never sends alerts. `NSSupportsLiveActivitiesFrequentUpdates` stays off unless measurement shows priority-10 throttling.
3. **A relay holds the APNs key.** A Cloudflare Worker in `relay/` (TypeScript) keeps the `.p8` keys as secrets, signs the ES256 provider JWT (reused for 50 minutes per key, per isolate), and sends one APNs request per token to the sandbox or production host by the token's `env`. Topics are fixed to the Levels bundle ID; the relay only sends `widgets` and `liveactivity` pushes, never `alert`, never `event: start`. The Mac never sees the key.
4. **Who may push to an iPhone is decided by that iPhone.** The iPhone app (not the widget extension; extensions can't use App Attest) proves it is a genuine Levels app with App Attest once, then asks the relay for a **grant**: a relay-signed statement that "the Mac with public key M may push to tokens T1…Tn in environment E until date D". It hands the grant to its paired Mac over the encrypted hub (ADR-0020). The Mac sends the grant with each push and signs each request with the private key for M. The relay checks the grant, the signature and that every token in the body is in a grant. The Mac doesn't need App Attest, which macOS 26 lacks.
5. **Stateless relay.** Challenges, device credentials and grants are HMAC-signed blobs. The relay keeps no database; the only state is rate-limit counters in Durable Objects, keyed by token hashes and device IDs, deleted 25 hours after their last use. Rotating `RELAY_HMAC_KEY` revokes every credential and grant at once.
6. **Privacy.** The relay logs nothing about requests (observability off, no `console` calls with request data). It never stores a raw token. It sees push tokens and, for the Live Activity, a level and charging state with no device names (names live in the activity's static attributes, set on the iPhone). This amends ADR-0019 Decision 1 ("nothing goes to any other server") for the push path only; the privacy policy must say so.
7. **API.** `POST /v1/widget-push` for the Mac, exactly as the brief set it, plus three iPhone routes (`/v1/challenge`, `/v1/attest`, `/v1/grant`). PUSH-001 has the exact contract and headers.
8. **When it turns on.** Only after enrollment (owner decision U). Until then the code, the relay and its tests exist; the Swift side ships behind a flag that is off.

## Threat model

Assets: the APNs signing keys; the owner's and users' devices (budget, battery, what their Lock Screen shows); the relay's Cloudflare quota; users' privacy.

| # | Threat | Mitigation | Left over |
|---|---|---|---|
| T1 | APNs key extracted from the public Mac app. | The key is only in Worker secrets. | A Cloudflare account takeover. Use 2FA; keys can be revoked in the developer account. |
| T2 | Someone uses the relay as a free push cannon. | Topics are fixed to Levels; only widget reloads and silent Live Activity updates can be sent; every token must be in a grant from an attested iPhone. | None for other apps. |
| T3 | An attacker with the Mac app's binary forges requests. | No shared secret exists in the app. Each Mac has its own key pair; a grant names one Mac key; the request signature covers timestamp, path and body hash. | A thief of a Mac's private key can push to the tokens granted to that Mac, within rate limits, until the grant expires (30 days). |
| T4 | A modified or fake iPhone app mints grants for random tokens to flood APNs or exhaust the relay. | App Attest: only a genuine Levels app on real Apple hardware gets a credential. Grants per device 30/hour; challenges, attests and grants 60/hour per IP (keyed hash). | A jailbroken device with a genuine app can still mint grants, but only for itself, and each is rate-limited. App Attest fraud metrics (receipts) aren't used yet. |
| T5 | Request flood with junk. | Size cap 8 KB, cheap HMAC check before any APNs call, 401 before 400 (no validation hints to strangers). Cloudflare's own DDoS protection; a WAF rate rule can be added in the dashboard. | Quota burn by junk requests on the free plan. |
| T6 | Replay of a captured Mac request or iPhone assertion. | Mac requests: timestamp within ±5 min, and per-token rate limits. Assertions: one-time-looking challenge that expires in 5 min (stateless, so reuse within 5 min isn't detected). | Within 5 min a replay repeats the same pushes or mints the same grant. Harmless. |
| T7 | A push token leaks (for example from a backup of the Mac). | Without a matching grant and Mac key it is useless at the relay. With APNs directly it needs our key. | None. |
| T8 | Live Activity content spoofing. | Same as T3: needs the Mac's key and a grant for that activity's token. No alert can be sent. | A stolen Mac key could show a wrong level for up to 8 hours. |
| T9 | The relay operator (us) learns usage patterns. | No logs; counters keyed by hashes and deleted after 25 hours; Live Activity payload has no names. | Cloudflare sees IPs and timing at the network level. |
| T10 | Too-frequent JWT refreshes (`TooManyProviderTokenUpdates`). | JWT reused for 50 min per key per isolate. | Many isolates each sign their own JWT; fine at Levels' scale. Move the JWT into a Durable Object if APNs complains. |

## Options considered

### Option A — Widget push + optional Live Activity, via a relay with iPhone-issued grants (chosen)
- Pros: the key stays off users' machines; works with macOS 26; the authorization matches reality (the phone decides who may wake it); stateless relay; tiny cost.
- Cons: a server to run and pay for (Cloudflare); an App Attest round trip on the iPhone; the widget gains little away from home.

### Option B — Mac proves itself with App Attest
- Pros: one fewer hop; the Mac proves it is genuine.
- Cons: not on macOS 26; Developer ID support only reported on forums for macOS 27; still needs grants to stop a genuine Mac pushing to other people's tokens. Later hardening, not the base.

### Option C — Ship the APNs key in the Mac app
- Pros: no server.
- Cons: anyone can extract it and push to Levels users' widgets and Live Activities with our identity; Apple can revoke it. Rejected.

### Option D — Live Activity only
- Pros: near-real-time with data in the push; works away from home.
- Cons: 8-hour limit; needs the user to start it; App Review expects a task with an end, not an always-on dashboard. Kept as the optional extra, not the main path.

### Option E — Relay stores an end-to-end-encrypted snapshot for the widget to fetch away from home
- Pros: widget push would help away from home too.
- Cons: turns the relay into data storage; more privacy surface; iCloud (SYNC-001) solves "away from home" at enrollment anyway. Not now; open question in PUSH-001.

### Option F — Simple API key or per-install secret
- Pros: easy.
- Cons: any secret in a public binary is public. Rejected.

## Consequences

- Positive: on the home Wi-Fi the widget follows real changes within minutes instead of 15–60; a Live Activity gives seconds-level updates for charging; the APNs key never leaves Cloudflare.
- Negative / accepted risks: a small server to operate; the widget budget still caps updates per day; some widget pushes may be dropped by iOS; nothing is sent while the Mac sleeps; HTTP/2 from Workers is unverified (Assumption); the privacy policy must mention the relay.
- Follow-ups: verify HTTP/2 and real pushes after enrollment (PUSH-001 AC12–AC15); measure how many widget pushes reload the widget; consider App Attest on the Mac when macOS 27 is the floor; consider App Attest receipts (fraud metric); when SYNC-001 replaces the hub (lead's call 27), decide whether the Mac keeps pushing or CloudKit silent pushes plus the app's own reload are enough.

## References

- [Updating widgets with WidgetKit push notifications](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications)
- [WidgetPushHandler](https://developer.apple.com/documentation/widgetkit/widgetpushhandler)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [WWDC25 What's new in widgets](https://developer.apple.com/videos/play/wwdc2025/278/)
- [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Sending notification requests to APNs](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [DCAppAttestService](https://developer.apple.com/documentation/devicecheck/dcappattestservice), [isSupported](https://developer.apple.com/documentation/devicecheck/dcappattestservice/issupported)
- [Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [Apple App Attestation Root CA](https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem)
- Forum threads [795627](https://developer.apple.com/forums/thread/795627), [839182](https://developer.apple.com/forums/thread/839182), [831492](https://developer.apple.com/forums/thread/831492), [836329](https://developer.apple.com/forums/thread/836329)
