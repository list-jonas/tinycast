// Byte codecs. JavaScriptCore has no TextEncoder/TextDecoder, so UTF-8 is by hand; base64 and hex
// use the native `Uint8Array› methods.

const STRING_CHUNK = 0x8000;

/// Joins code units in slices: one string per unit would build a rope node per character.
export function codeUnitsToString(units, length = units.length) {
  let out = "";
  for (let i = 0; i < length; i += STRING_CHUNK) {
    out += String.fromCharCode.apply(null, units.subarray(i, Math.min(i + STRING_CHUNK, length)));
  }
  return out;
}

export function utf8Encode(text) {
  let size = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.codePointAt(i);
    if (code > 0xffff) i++;
    size += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
  }
  const out = new Uint8Array(size);
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.codePointAt(i);
    if (code > 0xffff) i++;
    if (code < 0x80) {
      out[n++] = code;
    } else if (code < 0x800) {
      out[n++] = 0xc0 | (code >> 6);
      out[n++] = 0x80 | (code & 0x3f);
    } else if (code < 0x10000) {
      out[n++] = 0xe0 | (code >> 12);
      out[n++] = 0x80 | ((code >> 6) & 0x3f);
      out[n++] = 0x80 | (code & 0x3f);
    } else {
      out[n++] = 0xf0 | (code >> 18);
      out[n++] = 0x80 | ((code >> 12) & 0x3f);
      out[n++] = 0x80 | ((code >> 6) & 0x3f);
      out[n++] = 0x80 | (code & 0x3f);
    }
  }
  return out;
}

export function utf8Decode(bytes) {
  // A truncated four-byte lead at the end still yields a surrogate pair from one byte.
  const units = new Uint16Array(bytes.length + 1);
  let n = 0;
  for (let i = 0; i < bytes.length; ) {
    const byte = bytes[i++];
    if (byte < 0x80) units[n++] = byte;
    else if (byte < 0xe0) units[n++] = ((byte & 0x1f) << 6) | (bytes[i++] & 0x3f);
    else if (byte < 0xf0) units[n++] = ((byte & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
    else {
      const code = ((byte & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      if (code > 0x10ffff) throw new RangeError(`Invalid code point ${code}`);
      if (code < 0x10000) {
        units[n++] = code;
      } else {
        units[n++] = 0xd800 + ((code - 0x10000) >> 10);
        units[n++] = 0xdc00 + ((code - 0x10000) & 0x3ff);
      }
    }
  }
  return codeUnitsToString(units, n);
}

export const bytesToBase64 = (bytes) => (bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes)).toBase64();

/// Lenient like Node: anything outside the alphabet is skipped, and a dangling sextet is dropped.
export function base64ToBytes(text) {
  const clean = String(text).replace(/[^A-Za-z0-9+/]/g, "");
  return Uint8Array.fromBase64(clean.length % 4 === 1 ? clean.slice(0, -1) : clean, { lastChunkHandling: "loose" });
}

export function concatBytes(chunks) {
  const bytes = new Uint8Array(chunks.reduce((total, chunk) => total + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

