// `crypto` and `zlib`: the bytes cross to Swift as base64 and the work happens there.

import { hostCallSync } from "../host.js";
import { Buffer } from "../buffer.js";
import { base64ToBytes, bytesToBase64 } from "../bytes.js";
import { EventEmitter } from "../events.js";
import { Transform } from "../streams.js";
import { callbackify, codedError, hostBuffer, notSupported } from "./common.js";
import { unsupportedModule } from "./unsupported.js";

function cryptoBytes(value, encoding) {
  if (typeof value === "string") return Buffer.from(value, encoding || "utf8");
  if (ArrayBuffer.isView(value)) return Buffer.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  return Buffer.from(value);
}

const encoded = (bytes, encoding) => (encoding ? bytes.toString(encoding) : bytes);

export class Hash {
  constructor(algorithm, hmacKeyBase64) {
    this._algorithm = String(algorithm).toLowerCase().replace(/-/g, "");
    this._key = hmacKeyBase64;
    this._chunks = [];
  }
  update(data, encoding) {
    this._chunks.push(cryptoBytes(data, encoding));
    return this;
  }
  digest(encoding) {
    const input = bytesToBase64(Buffer.concat(this._chunks));
    return encoded(hostBuffer("crypto", this._key ? "hmac" : "hash", [this._algorithm, input, this._key ?? null]), encoding);
  }
}

const invalidState = () => codedError("Invalid state", "ERR_CRYPTO_INVALID_STATE");

// Buffers until `final›: a block cipher's concatenated output still matches Node's byte for byte.
class Cipher {
  constructor(algorithm, key, iv, decrypt) {
    const name = String(algorithm).toLowerCase().replace(/^aes(128|192|256)$/, "aes-$1-cbc");
    const match = /^aes-(128|192|256)-(cbc|ecb)$/.exec(name);
    if (!match) throw codedError("Unknown cipher", "ERR_CRYPTO_UNKNOWN_CIPHER");
    this._mode = match[2];
    this._key = cryptoBytes(key);
    this._iv = iv == null ? Buffer.alloc(0) : cryptoBytes(iv);
    if (this._key.length !== Number(match[1]) / 8) {
      throw codedError("Invalid key length", "ERR_CRYPTO_INVALID_KEYLEN", RangeError);
    }
    if (this._iv.length !== (this._mode === "cbc" ? 16 : 0)) {
      throw codedError("Invalid initialization vector", "ERR_CRYPTO_INVALID_IV", TypeError);
    }
    this._decrypt = decrypt;
    this._padding = true;
    this._chunks = [];
    this._finished = false;
  }
  update(data, inputEncoding, outputEncoding) {
    if (this._finished) throw new Error("Trying to add data in unsupported state");
    this._chunks.push(cryptoBytes(data, inputEncoding));
    return outputEncoding ? "" : Buffer.alloc(0);
  }
  final(outputEncoding) {
    if (this._finished) throw invalidState();
    this._finished = true;
    const [key, iv, data] = [this._key, this._iv, Buffer.concat(this._chunks)].map(bytesToBase64);
    return encoded(hostBuffer("crypto", "cipher", [this._mode, this._decrypt, key, iv, data, this._padding]), outputEncoding);
  }
  setAutoPadding(enabled = true) {
    if (this._finished) throw invalidState();
    this._padding = Boolean(enabled);
    return this;
  }
}

function pbkdf2Sync(password, salt, iterations, keylen, digest) {
  const [secret, seed] = [password, salt].map((value) => bytesToBase64(cryptoBytes(value)));
  return hostBuffer("crypto", "pbkdf2", [String(digest), secret, seed, Number(iterations), Number(keylen)]);
}

const randomBytes = (size) => base64ToBytes(hostCallSync("crypto", "random", [size]));

export const cryptoModule = {
  randomUUID: () => hostCallSync("crypto", "uuid", []),
  randomBytes(size, callback) {
    const bytes = hostBuffer("crypto", "random", [size | 0]);
    if (!callback) return bytes;
    queueMicrotask(() => callback(null, bytes));
  },
  randomFillSync(target) {
    target.set(randomBytes(target.length).subarray(0, target.length));
    return target;
  },
  randomInt(min, max) {
    if (max === undefined) {
      max = min;
      min = 0;
    }
    const bytes = randomBytes(4);
    const value = ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) >>> 0;
    return min + (value % (max - min));
  },
  createHash: (algorithm) => new Hash(algorithm),
  createHmac: (algorithm, key) => new Hash(algorithm, bytesToBase64(cryptoBytes(key))),
  createCipheriv: (algorithm, key, iv) => new Cipher(algorithm, key, iv, false),
  createDecipheriv: (algorithm, key, iv) => new Cipher(algorithm, key, iv, true),
  pbkdf2Sync,
  pbkdf2(password, salt, iterations, keylen, digest, callback) {
    if (typeof callback !== "function") {
      throw codedError('The "callback" argument must be of type function.', "ERR_INVALID_ARG_TYPE", TypeError);
    }
    const key = pbkdf2Sync(password, salt, iterations, keylen, digest);
    queueMicrotask(() => callback(null, key));
  },
  timingSafeEqual: (a, b) => Buffer.from(a).equals(Buffer.from(b)),
  getHashes: () => ["md5", "sha1", "sha256", "sha384", "sha512"],
  getRandomValues: (target) => cryptoModule.randomFillSync(target),
  webcrypto: null,
  constants: {},
};
cryptoModule.webcrypto = { randomUUID: cryptoModule.randomUUID, getRandomValues: cryptoModule.getRandomValues, subtle: undefined };
if (!globalThis.crypto) globalThis.crypto = cryptoModule.webcrypto;

const zlibSync = (method) => (data) => hostBuffer("zlib", method, [bytesToBase64(Buffer.from(data))]);

// minizlib swaps `Buffer.concat› for a no-op around `_processChunk›, so hold the real one.
const concatBuffers = Buffer.concat;

class Unzip extends EventEmitter {
  constructor() {
    super();
    this._chunks = [];
    this._handle = { close() {} };
  }
  _processChunk(chunk, flush) {
    this._chunks.push(Buffer.from(chunk));
    if (flush !== 4) return Buffer.alloc(0);
    const input = concatBuffers(this._chunks);
    this._chunks = [];
    if (!input.length) return input;
    return zlibSync(input[0] === 0x1f && input[1] === 0x8b ? "gunzip" : "inflate")(input);
  }
  close() {
    this._chunks = [];
    this._handle = null;
  }
}

const zlibImpl = {
  Unzip,
  brotliCompressSync: notSupported("zlib brotli"),
  brotliDecompressSync: notSupported("zlib brotli"),
  constants: {},
};
for (const name of ["gzip", "gunzip", "deflate", "inflate", "deflateRaw", "inflateRaw"]) {
  const sync = zlibSync(name);
  zlibImpl[`${name}Sync`] = sync;
  zlibImpl[name] = callbackify(sync);
  zlibImpl[`create${name[0].toUpperCase()}${name.slice(1)}`] = () => {
    const chunks = [];
    return new Transform({
      transform(chunk, _enc, cb) {
        chunks.push(Buffer.from(chunk));
        cb();
      },
      flush(cb) {
        try {
          cb(null, sync(concatBuffers(chunks)));
        } catch (error) {
          cb(error);
        }
      },
    });
  };
}
export const zlib = unsupportedModule("zlib", zlibImpl);

