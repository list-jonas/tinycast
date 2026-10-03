// A Buffer subset over Uint8Array — enough for the encode/decode and binary-parse work bundles do.
// Anything stream-shaped is deliberately absent; see docs/extensions.md for the supported surface.

import { base64ToBytes, bytesToBase64, codeUnitsToString, utf8Decode, utf8Encode } from "./bytes.js";

const ENCODINGS = {
  utf8: "utf8", "utf-8": "utf8",
  base64: "base64", base64url: "base64url", hex: "hex",
  latin1: "latin1", binary: "latin1", ascii: "latin1",
  utf16le: "utf16le", ucs2: "utf16le", "ucs-2": "utf16le", "utf-16le": "utf16le",
};

const normalizeEncoding = (encoding) => ENCODINGS[String(encoding || "utf8").toLowerCase()] ?? "utf8";

function decode(bytes, encoding) {
  switch (normalizeEncoding(encoding)) {
    case "base64":
      return bytesToBase64(bytes);
    case "base64url":
      return bytes.toBase64({ alphabet: "base64url", omitPadding: true });
    case "hex":
      return bytes.toHex();
    case "latin1":
      return codeUnitsToString(bytes);
    case "utf16le": {
      const units = new Uint16Array(bytes.length >> 1);
      for (let i = 0; i < units.length; i++) units[i] = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
      return codeUnitsToString(units);
    }
    default:
      return utf8Decode(bytes);
  }
}

function encode(text, encoding) {
  switch (normalizeEncoding(encoding)) {
    case "base64":
    case "base64url":
      return base64ToBytes(String(text).replace(/-/g, "+").replace(/_/g, "/"));
    case "hex": {
      const clean = String(text).replace(/[^0-9a-fA-F]/g, "");
      return Uint8Array.fromHex(clean.slice(0, clean.length & ~1));
    }
    case "latin1": {
      const source = String(text);
      const out = new Uint8Array(source.length);
      for (let i = 0; i < source.length; i++) out[i] = source.charCodeAt(i);
      return out;
    }
    case "utf16le": {
      const source = String(text);
      const out = new Uint8Array(source.length * 2);
      for (let i = 0; i < source.length; i++) {
        const code = source.charCodeAt(i);
        out[i * 2] = code & 0xff;
        out[i * 2 + 1] = code >> 8;
      }
      return out;
    }
    default:
      return utf8Encode(String(text));
  }
}

function compareBytes(a, b) {
  const shared = Math.min(a.length, b.length);
  for (let i = 0; i < shared; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  if (a.length === b.length) return 0;
  return a.length < b.length ? -1 : 1;
}

const dataViewOf = (buffer) => new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);

function outOfRange(name, min, max, received) {
  const error = new RangeError(`The value of "${name}" is out of range. It must be >= ${min} and <= ${max}. Received ${received}`);
  error.code = "ERR_OUT_OF_RANGE";
  return error;
}

function checkSpan(offset, ext, length) {
  const at = Number(offset) | 0;
  if (!Number.isInteger(Number(offset)) || at < 0 || at + ext > length) throw outOfRange("offset", 0, length - ext, offset);
  return at;
}

function checkInt(value, min, max) {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw outOfRange("value", min, max, value);
  }
}

function checkByteLength(byteLength) {
  if (byteLength < 1 || byteLength > 6) throw new RangeError("byteLength must be 1-6");
}

/// Variable-width integers, `byteLength› 1–6, in either byte order.
function readUIntGeneric(buffer, offset, byteLength, littleEndian) {
  const at = checkSpan(offset, byteLength, buffer.length);
  checkByteLength(byteLength);
  let value = 0;
  for (let i = 0; i < byteLength; i++) value = value * 256 + buffer[at + (littleEndian ? byteLength - 1 - i : i)];
  return value;
}

function readIntGeneric(buffer, offset, byteLength, littleEndian) {
  const unsigned = readUIntGeneric(buffer, offset, byteLength, littleEndian);
  return unsigned >= 2 ** (8 * byteLength - 1) ? unsigned - 2 ** (8 * byteLength) : unsigned;
}

function writeUIntGeneric(buffer, value, offset, byteLength, littleEndian) {
  const at = checkSpan(offset, byteLength, buffer.length);
  checkInt(value, 0, 2 ** (8 * byteLength) - 1);
  let rest = value;
  for (let i = 0; i < byteLength; i++) {
    buffer[at + (littleEndian ? i : byteLength - 1 - i)] = rest & 0xff;
    rest = Math.floor(rest / 256);
  }
  return at + byteLength;
}

function writeIntGeneric(buffer, value, offset, byteLength, littleEndian) {
  const at = checkSpan(offset, byteLength, buffer.length);
  const limit = 2 ** (8 * byteLength - 1);
  checkInt(value, -limit, limit - 1);
  return writeUIntGeneric(buffer, value < 0 ? value + 2 ** (8 * byteLength) : value, at, byteLength, littleEndian);
}

export class Buffer extends Uint8Array {
  static from(value, encodingOrOffset, length) {
    if (typeof value === "string") return adoptBytes(encode(value, encodingOrOffset));
    if (value instanceof ArrayBuffer) {
      const offset = encodingOrOffset || 0;
      return adoptBytes(new Uint8Array(value, offset, length === undefined ? value.byteLength - offset : length));
    }
    if (value instanceof Uint8Array || Array.isArray(value)) return adoptBytes(new Uint8Array(value));
    if (value && typeof value === "object" && value.type === "Buffer" && Array.isArray(value.data)) {
      return adoptBytes(new Uint8Array(value.data));
    }
    throw new TypeError("Buffer.from: unsupported input");
  }

  static alloc(size, fill) {
    const bytes = new Uint8Array(Math.max(0, size | 0));
    if (fill !== undefined && fill !== 0) {
      const value = typeof fill === "number" ? fill : encode(String(fill), "utf8")[0] ?? 0;
      bytes.fill(value & 0xff);
    }
    return adoptBytes(bytes);
  }

  static allocUnsafe(size) {
    return Buffer.alloc(size);
  }

  static concat(list, totalLength) {
    const parts = list.map((part) => (part instanceof Uint8Array ? part : Buffer.from(part)));
    const total = totalLength === undefined ? parts.reduce((sum, part) => sum + part.length, 0) : totalLength;
    const out = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      if (offset >= total) break;
      out.set(part.subarray(0, Math.min(part.length, total - offset)), offset);
      offset += part.length;
    }
    return adoptBytes(out);
  }

  static isBuffer(value) {
    return value instanceof Uint8Array;
  }

  static compare(a, b) {
    if (!(a instanceof Uint8Array) || !(b instanceof Uint8Array)) {
      throw new TypeError("Buffer.compare: inputs must be Buffers");
    }
    return compareBytes(a, b);
  }

  static isEncoding(encoding) {
    return Object.hasOwn(ENCODINGS, String(encoding || "").toLowerCase());
  }

  static byteLength(value, encoding) {
    if (typeof value === "string") return encode(value, encoding).length;
    return value?.length ?? 0;
  }

  toString(encoding, start, end) {
    return decode(this.subarray(start ?? 0, end ?? this.length), encoding);
  }

  toJSON() {
    return { type: "Buffer", data: Array.from(this) };
  }

  equals(other) {
    return other instanceof Uint8Array && other.length === this.length && compareBytes(this, other) === 0;
  }

  compare(target, targetStart, targetEnd, sourceStart, sourceEnd) {
    if (!(target instanceof Uint8Array)) throw new TypeError("Buffer.compare: target must be a Buffer");
    const targetSlice = target.subarray(targetStart ?? 0, targetEnd ?? target.length);
    const sourceSlice = this.subarray(sourceStart ?? 0, sourceEnd ?? this.length);
    return compareBytes(sourceSlice, targetSlice);
  }

  copy(target, targetStart = 0, sourceStart = 0, sourceEnd = this.length) {
    if (!(target instanceof Uint8Array)) throw new TypeError("Buffer.copy: target must be a Buffer");
    const count = Math.min(sourceEnd - sourceStart, target.length - targetStart);
    if (count <= 0) return 0;
    target.set(this.subarray(sourceStart, sourceStart + count), targetStart);
    return count;
  }

  subarray(start, end) {
    return adoptBytes(super.subarray(start, end));
  }

  slice(start, end) {
    return this.subarray(start, end);
  }

  write(text, offset = 0, length, encoding) {
    if (typeof length === "string") {
      encoding = length;
      length = undefined;
    }
    const bytes = encode(text, encoding);
    const count = Math.min(length ?? bytes.length, this.length - offset);
    this.set(bytes.subarray(0, count), offset);
    return count;
  }

  readUIntLE(offset, byteLength) {
    return readUIntGeneric(this, offset, byteLength, true);
  }
  readUIntBE(offset, byteLength) {
    return readUIntGeneric(this, offset, byteLength, false);
  }
  readIntLE(offset, byteLength) {
    return readIntGeneric(this, offset, byteLength, true);
  }
  readIntBE(offset, byteLength) {
    return readIntGeneric(this, offset, byteLength, false);
  }
  writeUIntLE(value, offset, byteLength) {
    return writeUIntGeneric(this, value, offset, byteLength, true);
  }
  writeUIntBE(value, offset, byteLength) {
    return writeUIntGeneric(this, value, offset, byteLength, false);
  }
  writeIntLE(value, offset, byteLength) {
    return writeIntGeneric(this, value, offset, byteLength, true);
  }
  writeIntBE(value, offset, byteLength) {
    return writeIntGeneric(this, value, offset, byteLength, false);
  }

  swap16() {
    return swapBytes(this, 2);
  }
  swap32() {
    return swapBytes(this, 4);
  }
  swap64() {
    return swapBytes(this, 8);
  }

  fill(value, offset = 0, end = this.length, encoding) {
    if (typeof value === "string") {
      const bytes = encode(value, encoding);
      if (!bytes.length) return this;
      const from = Math.max(0, offset);
      const to = Math.min(this.length, end);
      for (let i = from; i < to; i++) this[i] = bytes[(i - from) % bytes.length];
      return this;
    }
    return super.fill(value ?? 0, offset, end);
  }
}

function swapBytes(buffer, width) {
  if (buffer.length % width !== 0) throw new RangeError(`Buffer size must be a multiple of ${width * 8}-bits`);
  for (let i = 0; i < buffer.length; i += width) buffer.subarray(i, i + width).reverse();
  return buffer;
}

const define = (name, value) =>
  Object.defineProperty(Buffer.prototype, name, { value, writable: true, configurable: true });
const byteOrders = (width) => (width === 1 ? [["", false]] : [["LE", true], ["BE", false]]);

for (const [name, width] of [["UInt8", 1], ["UInt16", 2], ["UInt32", 4], ["Int8", 1], ["Int16", 2], ["Int32", 4]]) {
  const unsigned = name.startsWith("U");
  const [read, write] = unsigned ? [readUIntGeneric, writeUIntGeneric] : [readIntGeneric, writeIntGeneric];
  const [min, max] = unsigned ? [0, 2 ** (8 * width) - 1] : [-(2 ** (8 * width - 1)), 2 ** (8 * width - 1) - 1];
  for (const [suffix, littleEndian] of byteOrders(width)) {
    define(`read${name}${suffix}`, function (offset = 0) {
      return read(this, offset, width, littleEndian);
    });
    define(`write${name}${suffix}`, function (value, offset = 0) {
      checkInt(value, min, max);
      return write(this, value, offset, width, littleEndian);
    });
  }
}

for (const [name, view, width, convert] of [
  ["Float", "Float32", 4, Number],
  ["Double", "Float64", 8, Number],
  ["BigUInt64", "BigUint64", 8, BigInt],
  ["BigInt64", "BigInt64", 8, BigInt],
]) {
  for (const [suffix, littleEndian] of byteOrders(width)) {
    define(`read${name}${suffix}`, function (offset = 0) {
      return dataViewOf(this)[`get${view}`](checkSpan(offset, width, this.length), littleEndian);
    });
    define(`write${name}${suffix}`, function (value, offset = 0) {
      const converted = convert(value);
      const at = checkSpan(offset, width, this.length);
      dataViewOf(this)[`set${view}`](at, converted, littleEndian);
      return at + width;
    });
  }
}

for (const name of Object.getOwnPropertyNames(Buffer.prototype)) {
  if (/^(read|write)UInt/.test(name)) Buffer.prototype[name.replace("UInt", "Uint")] = Buffer.prototype[name];
}

// Node's statics are enumerable; safer-buffer copies them by `for…in›, else calls Buffer bare.
for (const name of Object.getOwnPropertyNames(Buffer)) {
  if (typeof Buffer[name] === "function") Object.defineProperty(Buffer, name, { enumerable: true });
}

/// Grafts the Buffer prototype onto fresh bytes: subclassing and then copying would double every
/// allocation for large payloads.
export function adoptBytes(bytes) {
  Object.setPrototypeOf(bytes, Buffer.prototype);
  return bytes;
}

export const bufferModule = {
  Buffer,
  SlowBuffer: Buffer,
  atob: globalThis.atob,
  btoa: globalThis.btoa,
  constants: { MAX_LENGTH: 0x7fffffff, MAX_STRING_LENGTH: 0x1fffffe8 },
  kMaxLength: 0x7fffffff,
  isEncoding: (encoding) => Buffer.isEncoding(encoding),
  isBuffer: (value) => Buffer.isBuffer(value),
};
