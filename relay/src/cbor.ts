// Minimal CBOR (RFC 8949) decoder for App Attest objects: definite-length
// integers, byte strings, text strings, arrays, maps and simple values. Map
// keys stay as decoded (string or number). Anything else throws.

export type CborValue =
  | number
  | bigint
  | string
  | boolean
  | null
  | undefined
  | Uint8Array
  | CborValue[]
  | Map<CborValue, CborValue>;

const MAX_DEPTH = 16;

export function decodeCbor(bytes: Uint8Array): CborValue {
  const r = new Reader(bytes);
  const v = r.item(0);
  if (r.pos !== bytes.length) throw new Error("cbor: trailing bytes");
  return v;
}

/** Decodes the first item and returns it with the number of bytes it used. */
export function decodeCborPrefix(bytes: Uint8Array): { value: CborValue; length: number } {
  const r = new Reader(bytes);
  const value = r.item(0);
  return { value, length: r.pos };
}

class Reader {
  pos = 0;
  constructor(private readonly b: Uint8Array) {}

  private byte(): number {
    if (this.pos >= this.b.length) throw new Error("cbor: truncated");
    return this.b[this.pos++]!;
  }

  private take(n: number): Uint8Array {
    if (n > this.b.length - this.pos) throw new Error("cbor: truncated");
    const out = this.b.slice(this.pos, this.pos + n);
    this.pos += n;
    return out;
  }

  private argument(info: number): number | bigint {
    if (info < 24) return info;
    if (info === 24) return this.byte();
    if (info === 25) return (this.byte() << 8) | this.byte();
    if (info === 26) {
      const v = this.take(4);
      return ((v[0]! << 24) >>> 0) + (v[1]! << 16) + (v[2]! << 8) + v[3]!;
    }
    if (info === 27) {
      const v = this.take(8);
      let n = 0n;
      for (const x of v) n = (n << 8n) | BigInt(x);
      return n <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(n) : n;
    }
    throw new Error("cbor: indefinite or reserved length");
  }

  private length(info: number): number {
    const n = this.argument(info);
    if (typeof n !== "number") throw new Error("cbor: length too large");
    return n;
  }

  item(depth: number): CborValue {
    if (depth > MAX_DEPTH) throw new Error("cbor: too deep");
    const initial = this.byte();
    const major = initial >> 5;
    const info = initial & 0x1f;
    switch (major) {
      case 0:
        return this.argument(info);
      case 1: {
        const n = this.argument(info);
        return typeof n === "number" ? -1 - n : -1n - n;
      }
      case 2:
        return this.take(this.length(info));
      case 3:
        return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(this.take(this.length(info)));
      case 4: {
        const n = this.length(info);
        if (n > this.b.length) throw new Error("cbor: array too long");
        const out: CborValue[] = [];
        for (let i = 0; i < n; i++) out.push(this.item(depth + 1));
        return out;
      }
      case 5: {
        const n = this.length(info);
        if (n > this.b.length) throw new Error("cbor: map too long");
        const out = new Map<CborValue, CborValue>();
        for (let i = 0; i < n; i++) {
          const k = this.item(depth + 1);
          out.set(k, this.item(depth + 1));
        }
        return out;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        if (info === 23) return undefined;
        throw new Error("cbor: unsupported simple value");
      default:
        throw new Error("cbor: unsupported major type");
    }
  }
}
