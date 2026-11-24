import "reflect-metadata";
import * as x509 from "@peculiar/x509";
import { ProviderTokenCache, type Clock } from "../src/apns.js";
import { concat, sha256, toBase64, toBase64Url, utf8 } from "../src/bytes.js";
import type { Env } from "../src/env.js";
import { handle, type Deps } from "../src/index.js";
import { MemoryRateLimiter } from "../src/ratelimit.js";
import { signingString } from "../src/auth.js";
import { Signer, tokenHash, type GrantBody } from "../src/signed.js";

x509.cryptoProvider.set(crypto);

export const HMAC_KEY = "dGVzdC1rZXktdGVzdC1rZXktdGVzdC1rZXktdGVzdC0xMjM0NQ==";
export const T0 = 1_800_000_000; // a fixed "now"

export class FakeClock implements Clock {
  constructor(public t = T0) {}
  now() {
    return this.t;
  }
}

export async function p8Pair(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
  const b64 = toBase64(der).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, publicKey: kp.publicKey };
}

export interface TestWorld {
  env: Env;
  deps: Deps;
  clock: FakeClock;
  calls: { url: string; init: RequestInit }[];
  respond: (url: string, init: RequestInit) => Response;
  sandboxPub: CryptoKey;
  productionPub: CryptoKey;
  limiter: MemoryRateLimiter;
}

export async function world(): Promise<TestWorld> {
  const sandbox = await p8Pair();
  const production = await p8Pair();
  const clock = new FakeClock();
  const calls: { url: string; init: RequestInit }[] = [];
  const w: TestWorld = {
    env: {
      IOS_BUNDLE_ID: "com.example.levels",
      APPLE_TEAM_ID: "TEAM123456",
      APNS_KEY_ID_SANDBOX: "SANDBOX123",
      APNS_KEY_ID_PRODUCTION: "PRODKEY123",
      APNS_KEY_SANDBOX: sandbox.pem,
      APNS_KEY_PRODUCTION: production.pem,
      RELAY_HMAC_KEY: HMAC_KEY,
      RATE_LIMITER: undefined as unknown as DurableObjectNamespace,
    },
    clock,
    calls,
    respond: () => new Response(null, { status: 200, headers: { "apns-id": "11111111-1111-1111-1111-111111111111" } }),
    sandboxPub: sandbox.publicKey,
    productionPub: production.publicKey,
    limiter: new MemoryRateLimiter(() => clock.now()),
    deps: undefined as unknown as Deps,
  };
  w.deps = {
    transport: async (url, init) => {
      calls.push({ url, init });
      return w.respond(url, init);
    },
    limiter: w.limiter,
    clock,
    tokens: new ProviderTokenCache(clock),
  };
  return w;
}

export async function macKeyPair(): Promise<{ priv: CryptoKey; rawPub: Uint8Array }> {
  const kp = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  return { priv: kp.privateKey, rawPub: new Uint8Array((await crypto.subtle.exportKey("raw", kp.publicKey)) as ArrayBuffer) };
}

export const WIDGET_TOKEN = "a".repeat(64);
export const LA_TOKEN = "b".repeat(160);

export async function makeGrant(
  w: TestWorld,
  macPub: Uint8Array,
  tokens: { kind: "widget" | "liveActivity"; token: string }[],
  opts: { env?: "development" | "production"; exp?: number; dev?: string; key?: string } = {},
): Promise<string> {
  const signer = await Signer.create(opts.key ?? w.env.RELAY_HMAC_KEY);
  const body: GrantBody = {
    v: 1,
    env: opts.env ?? "production",
    mac: toBase64Url(macPub),
    dev: opts.dev ?? "device-one-00000000",
    t: await Promise.all(tokens.map(async (t) => [t.kind, await tokenHash(t.token)] as GrantBody["t"][number])),
    iat: w.clock.now(),
    exp: opts.exp ?? w.clock.now() + 3600,
  };
  return signer.seal("g1", body);
}

export async function signedPush(
  w: TestWorld,
  mac: { priv: CryptoKey },
  grant: string,
  body: unknown,
  opts: { ts?: number; path?: string; tamper?: boolean } = {},
): Promise<Response> {
  const bytes = utf8.encode(typeof body === "string" ? body : JSON.stringify(body));
  const ts = String(opts.ts ?? w.clock.now());
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      mac.priv,
      utf8.encode(await signingString(ts, "POST", "/v1/widget-push", bytes)),
    ),
  );
  const sent = opts.tamper ? concat(bytes, utf8.encode(" ")) : bytes;
  return handle(
    new Request(`https://relay.example${opts.path ?? "/v1/widget-push"}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "levels-grant": grant,
        "levels-timestamp": ts,
        "levels-signature": toBase64Url(sig),
        "content-length": String(sent.length),
      },
      body: sent,
    }),
    w.env,
    w.deps,
  );
}

/** Node's Request doesn't add Content-Length; the relay requires it, so the helpers set it. */
export function post(w: TestWorld, path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  const bytes = utf8.encode(typeof body === "string" ? body : JSON.stringify(body));
  return handle(
    new Request(`https://relay.example${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", "content-length": String(bytes.length), ...headers },
      body: bytes,
    }),
    w.env,
    w.deps,
  );
}

// ---------------------------------------------------------------- CBOR (test-only encoder)

function head(major: number, n: number): Uint8Array {
  if (n < 24) return new Uint8Array([(major << 5) | n]);
  if (n < 256) return new Uint8Array([(major << 5) | 24, n]);
  if (n < 65536) return new Uint8Array([(major << 5) | 25, n >> 8, n & 0xff]);
  return new Uint8Array([(major << 5) | 26, (n >>> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
}

export type Enc = number | string | Uint8Array | Enc[] | Map<Enc, Enc>;

export function cbor(v: Enc): Uint8Array {
  if (typeof v === "number") return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (typeof v === "string") {
    const b = utf8.encode(v);
    return concat(head(3, b.length), b);
  }
  if (v instanceof Uint8Array) return concat(head(2, v.length), v);
  if (Array.isArray(v)) return concat(head(4, v.length), ...v.map(cbor));
  const parts: Uint8Array[] = [head(5, v.size)];
  for (const [k, x] of v) parts.push(cbor(k), cbor(x));
  return concat(...parts);
}

// ---------------------------------------------------------------- Fake App Attest

export const APP_ID = "TEAM123456.com.example.levels";

export interface FakeAttestKit {
  rootPem: string;
  intermediate: { cert: x509.X509Certificate; keys: CryptoKeyPair };
  root: { cert: x509.X509Certificate; keys: CryptoKeyPair };
}

const P384 = { name: "ECDSA", namedCurve: "P-384", hash: "SHA-384" } as const;

export async function fakeAttestKit(): Promise<FakeAttestKit> {
  const rootKeys = (await crypto.subtle.generateKey(P384, true, ["sign", "verify"])) as CryptoKeyPair;
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Fake App Attestation Root CA",
    notBefore: new Date((T0 - 86400 * 365) * 1000),
    notAfter: new Date((T0 + 86400 * 365) * 1000),
    signingAlgorithm: P384,
    keys: rootKeys,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });
  const intKeys = (await crypto.subtle.generateKey(P384, true, ["sign", "verify"])) as CryptoKeyPair;
  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Fake App Attestation CA 1",
    issuer: root.subject,
    notBefore: new Date((T0 - 86400 * 30) * 1000),
    notAfter: new Date((T0 + 86400 * 30) * 1000),
    signingAlgorithm: P384,
    publicKey: intKeys.publicKey,
    signingKey: rootKeys.privateKey,
    extensions: [new x509.BasicConstraintsExtension(true, 0, true)],
  });
  return { rootPem: root.toString("pem"), root: { cert: root, keys: rootKeys }, intermediate: { cert: intermediate, keys: intKeys } };
}

export interface FakeDevice {
  keyId: string; // base64 SHA-256 of raw public key
  keys: CryptoKeyPair;
  rawPub: Uint8Array;
  counter: number;
}

export async function fakeDevice(): Promise<FakeDevice> {
  const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const rawPub = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  return { keyId: toBase64(await sha256(rawPub)), keys, rawPub, counter: 0 };
}

export const AAGUID_PROD = concat(utf8.encode("appattest"), new Uint8Array(7));
export const AAGUID_DEV = utf8.encode("appattestdevelop");

export async function attestationObject(
  kit: FakeAttestKit,
  dev: FakeDevice,
  challenge: string,
  o: { appId?: string; aaguid?: Uint8Array; counter?: number; wrongNonce?: boolean; extensions?: Map<Enc, Enc>; credId?: Uint8Array } = {},
): Promise<Uint8Array> {
  const keyIdBytes = await sha256(dev.rawPub);
  const cose = cbor(new Map<Enc, Enc>([[1, 2], [3, -7], [-1, 1], [-2, dev.rawPub.slice(1, 33)], [-3, dev.rawPub.slice(33)]]));
  const credId = o.credId ?? keyIdBytes;
  const counter = o.counter ?? 0;
  const flags = 0x40 | (o.extensions ? 0x80 : 0);
  const authData = concat(
    await sha256(o.appId ?? APP_ID),
    new Uint8Array([flags, (counter >>> 24) & 0xff, (counter >> 16) & 0xff, (counter >> 8) & 0xff, counter & 0xff]),
    o.aaguid ?? AAGUID_PROD,
    new Uint8Array([credId.length >> 8, credId.length & 0xff]),
    credId,
    cose,
    o.extensions ? cbor(o.extensions) : new Uint8Array(0),
  );
  let nonce = await sha256(concat(authData, await sha256(challenge)));
  if (o.wrongNonce) nonce = await sha256("nope");
  const extValue = concat(new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]), nonce);
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03",
    subject: "CN=fake-credential",
    issuer: kit.intermediate.cert.subject,
    notBefore: new Date((T0 - 86400) * 1000),
    notAfter: new Date((T0 + 86400) * 1000),
    signingAlgorithm: P384,
    publicKey: dev.keys.publicKey,
    signingKey: kit.intermediate.keys.privateKey,
    extensions: [new x509.Extension("1.2.840.113635.100.8.2", false, extValue)],
  });
  return cbor(
    new Map<Enc, Enc>([
      ["fmt", "apple-appattest"],
      [
        "attStmt",
        new Map<Enc, Enc>([
          ["x5c", [new Uint8Array(leaf.rawData), new Uint8Array(kit.intermediate.cert.rawData)]],
          ["receipt", new Uint8Array([1, 2, 3])],
        ]),
      ],
      ["authData", authData],
    ]),
  );
}

export function rawToDer(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let v = b;
    while (v.length > 1 && v[0] === 0 && v[1]! < 0x80) v = v.slice(1);
    if (v[0]! >= 0x80) v = concat(new Uint8Array([0]), v);
    return concat(new Uint8Array([0x02, v.length]), v);
  };
  const body = concat(int(raw.slice(0, 32)), int(raw.slice(32)));
  return concat(new Uint8Array([0x30, body.length]), body);
}

export async function assertionObject(
  dev: FakeDevice,
  clientData: Uint8Array,
  o: { appId?: string; counter?: number; badSig?: boolean } = {},
): Promise<Uint8Array> {
  dev.counter += 1;
  const counter = o.counter ?? dev.counter;
  const authenticatorData = concat(
    await sha256(o.appId ?? APP_ID),
    new Uint8Array([0x00, (counter >>> 24) & 0xff, (counter >> 16) & 0xff, (counter >> 8) & 0xff, counter & 0xff]),
  );
  const nonce = await sha256(concat(authenticatorData, await sha256(clientData)));
  const raw = new Uint8Array(
    (await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, dev.keys.privateKey, nonce)) as ArrayBuffer,
  );
  if (o.badSig) raw[10] = raw[10]! ^ 0xff;
  return cbor(new Map<Enc, Enc>([["signature", rawToDer(raw)], ["authenticatorData", authenticatorData]]));
}
