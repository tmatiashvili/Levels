// Worker bindings. Plain vars live in wrangler.toml [vars]; secrets are set
// with `wrangler secret put` and never committed (PUSH-001 "Owner setup").

export interface Env {
  // --- vars ---
  /** iOS app bundle ID, e.g. "com.tmatiashvili.levels". APNs topics are built from it. */
  IOS_BUNDLE_ID: string;
  /** 10-character Apple Team ID. JWT `iss` and the App Attest App ID prefix. */
  APPLE_TEAM_ID: string;
  /** Key ID of the sandbox APNs key (or of a key valid for both environments). */
  APNS_KEY_ID_SANDBOX?: string;
  /** Key ID of the production APNs key (or of a key valid for both environments). */
  APNS_KEY_ID_PRODUCTION?: string;

  // --- secrets ---
  /** Contents of the sandbox AuthKey_XXXXXXXXXX.p8 (PEM, PKCS#8). */
  APNS_KEY_SANDBOX?: string;
  /** Contents of the production AuthKey_XXXXXXXXXX.p8 (PEM, PKCS#8). */
  APNS_KEY_PRODUCTION?: string;
  /** At least 32 random bytes, base64. Signs challenges, device credentials and grants. */
  RELAY_HMAC_KEY: string;
  /** The previous RELAY_HMAC_KEY during a rotation; verify-only. */
  RELAY_HMAC_KEY_PREVIOUS?: string;

  // --- bindings ---
  RATE_LIMITER: DurableObjectNamespace;
}
