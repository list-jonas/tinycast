// `fetch` and its companions — Headers, Blob, File, FormData, Request, Response, AbortController.
// Backed by URLSession on the Swift side; bodies cross the bridge base64-encoded so binary survives.

import { hostCall, reportUncaught } from "./host.js";
import { base64ToBytes, bytesToBase64, concatBytes, utf8Decode, utf8Encode } from "./bytes.js";
import {
  ReadableStream,
  TransformStream,
  WritableStream,
  bytesOfReadableStream,
  readableStreamOfBytes,
} from "./web-streams.js";

const g = globalThis;

class TinycastHeaders {
  constructor(init) {
    this._map = new Map();
    if (init instanceof TinycastHeaders) {
      for (const [key, value] of init._map) this._map.set(key, value);
    } else if (Array.isArray(init)) {
      for (const [key, value] of init) this.append(key, value);
    } else if (init && typeof init === "object") {
      for (const key of Object.keys(init)) this.append(key, init[key]);
    }
  }
  _key(name) {
    return String(name).toLowerCase();
  }
  append(name, value) {
    const key = this._key(name);
    const existing = this._map.get(key);
    this._map.set(key, existing === undefined ? String(value) : `${existing}, ${value}`);
  }
  set(name, value) {
    this._map.set(this._key(name), String(value));
  }
  get(name) {
    const value = this._map.get(this._key(name));
    return value === undefined ? null : value;
  }
  has(name) {
    return this._map.has(this._key(name));
  }
  delete(name) {
    this._map.delete(this._key(name));
  }
  forEach(fn, thisArg) {
    for (const [key, value] of this._map) fn.call(thisArg, value, key, this);
  }
  keys() {
    return this._map.keys();
  }
  values() {
    return this._map.values();
  }
  entries() {
    return this._map.entries();
  }
  [Symbol.iterator]() {
    return this._map.entries();
  }
  toJSON() {
    return Object.fromEntries(this._map);
  }
}

const EMPTY_BYTES = new Uint8Array(0);

class TinycastBlob {
  constructor(parts = [], options = {}) {
    this._bytes = concatBytes((parts ?? []).map(blobPartToBytes));
    const type = String(options?.type ?? "");
    this._type = /^[\x20-\x7e]*$/.test(type) ? type.toLowerCase() : "";
  }
  get size() {
    return this._bytes.length;
  }
  get type() {
    return this._type;
  }
  async arrayBuffer() {
    return this._bytes.slice().buffer;
  }
  async bytes() {
    return this._bytes.slice();
  }
  async text() {
    return utf8Decode(this._bytes);
  }
  stream() {
    return readableStreamOfBytes(this._bytes);
  }
  slice(start = 0, end = this.size, contentType = "") {
    const from = normalizeBlobIndex(start, this.size);
    const to = normalizeBlobIndex(end, this.size);
    return new TinycastBlob([this._bytes.subarray(Math.min(from, to), to)], { type: contentType });
  }
}

function blobPartToBytes(part) {
  if (part instanceof TinycastBlob) return part._bytes;
  if (typeof part === "string") return utf8Encode(part);
  if (part instanceof ArrayBuffer) return new Uint8Array(part);
  if (ArrayBuffer.isView(part)) return new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
  return utf8Encode(String(part));
}

function normalizeBlobIndex(value, size) {
  const index = Number(value);
  if (Number.isNaN(index)) return 0;
  if (index === Infinity) return size;
  if (index === -Infinity) return 0;
  return Math.min(Math.max(index < 0 ? size + Math.ceil(index) : Math.floor(index), 0), size);
}

class TinycastFile extends TinycastBlob {
  constructor(parts = [], name = "", options = {}) {
    super(parts, options);
    this.name = String(name);
    this.lastModified = options?.lastModified ?? Date.now();
  }
}

class TinycastFormData {
  constructor() {
    this._entries = [];
    // Header and body must carry the same boundary, so it lives on the instance, not the encoder.
    this._boundary = `----TinycastFormBoundary${Math.random().toString(36).slice(2, 18)}`;
  }
  append(name, value, filename) {
    this._entries.push([String(name), formDataValue(value, filename)]);
  }
  set(name, value, filename) {
    const key = String(name);
    const at = this._entries.findIndex(([existing]) => existing === key);
    this._entries = this._entries.filter(([existing]) => existing !== key);
    this._entries.splice(at === -1 ? this._entries.length : at, 0, [key, formDataValue(value, filename)]);
  }
  get(name) {
    const hit = this._entries.find(([existing]) => existing === String(name));
    return hit === undefined ? null : hit[1];
  }
  getAll(name) {
    return this._entries.filter(([existing]) => existing === String(name)).map(([, value]) => value);
  }
  has(name) {
    return this._entries.some(([existing]) => existing === String(name));
  }
  delete(name) {
    this._entries = this._entries.filter(([existing]) => existing !== String(name));
  }
  forEach(fn, thisArg) {
    for (const [name, value] of this._entries) fn.call(thisArg, value, name, this);
  }
  keys() {
    return this._entries.map(([name]) => name)[Symbol.iterator]();
  }
  values() {
    return this._entries.map(([, value]) => value)[Symbol.iterator]();
  }
  entries() {
    return this._entries.map(([name, value]) => [name, value])[Symbol.iterator]();
  }
  [Symbol.iterator]() {
    return this.entries();
  }
}

// A Blob entry becomes a File named "blob" unless the caller passed a filename, per the spec.
function formDataValue(value, filename) {
  if (!(value instanceof TinycastBlob)) return String(value);
  if (value instanceof TinycastFile && filename === undefined) return value;
  return new TinycastFile([value], filename ?? "blob", { type: value.type });
}

function formDataToBytes(form) {
  const chunks = [];
  for (const [name, value] of form._entries) {
    const disposition =
      value instanceof TinycastBlob
        ? `; name="${escapeFormName(name)}"; filename="${escapeFormName(value.name)}"`
        : `; name="${escapeFormName(name)}"`;
    const type = value instanceof TinycastBlob ? `Content-Type: ${value.type || "application/octet-stream"}\r\n` : "";
    chunks.push(utf8Encode(`--${form._boundary}\r\nContent-Disposition: form-data${disposition}\r\n${type}\r\n`));
    chunks.push(value instanceof TinycastBlob ? value._bytes : utf8Encode(value));
    chunks.push(utf8Encode("\r\n"));
  }
  chunks.push(utf8Encode(`--${form._boundary}--\r\n`));
  return concatBytes(chunks);
}

function escapeFormName(value) {
  return String(value).replace(/\n/g, "%0A").replace(/\r/g, "%0D").replace(/"/g, "%22");
}

if (!g.Blob) g.Blob = TinycastBlob;
if (!g.File) g.File = TinycastFile;
if (!g.FormData) g.FormData = TinycastFormData;

class TinycastResponse {
  // Spec shape: axios and friends construct a Response at module scope to probe the platform.
  constructor(body = null, init = {}, url = "") {
    this.status = init.status ?? 200;
    this.statusText = init.statusText ?? "";
    this.headers = new TinycastHeaders(init.headers);
    this.url = url;
    this.ok = this.status >= 200 && this.status < 300;
    this.redirected = false;
    this.type = "basic";
    this._stream = body instanceof ReadableStream ? body : null;
    this._bytes = this._stream ? null : (bodyToBytes(body) ?? EMPTY_BYTES);
    this._hasBody = body !== null && body !== undefined;
    this.bodyUsed = false;
  }
  // The bytes are already here, so the "stream" hands them out in reader-sized pieces — enough for
  // an extension that guards on `response.body` and pipes it, but never progressive.
  get body() {
    if (!this._hasBody) return null;
    if (!this._stream) this._stream = readableStreamOfBytes(this._bytes);
    return this._stream;
  }
  clone() {
    const { status, statusText, headers } = this;
    return new TinycastResponse(this._bytes ?? this._stream, { status, statusText, headers }, this.url);
  }
  async arrayBuffer() {
    this.bodyUsed = true;
    return (await this.bytes()).buffer;
  }
  // A copy: the body outlives the read, so a caller mutating it must not affect the next reader.
  async bytes() {
    this.bodyUsed = true;
    if (this._bytes === null) this._bytes = await bytesOfReadableStream(this._stream);
    return this._bytes.slice();
  }
  async text() {
    this.bodyUsed = true;
    if (this._bytes === null) this._bytes = await bytesOfReadableStream(this._stream);
    return utf8Decode(this._bytes);
  }
  async json() {
    return JSON.parse(await this.text());
  }
  async blob() {
    return new TinycastBlob([await this.bytes()], { type: this.headers.get("content-type") ?? "" });
  }
}

class TinycastRequest {
  constructor(input, init = {}) {
    if (input instanceof TinycastRequest) {
      this.url = input.url;
      this.method = init.method || input.method;
      this.headers = new TinycastHeaders(init.headers || input.headers);
      this.body = init.body !== undefined ? init.body : input.body;
    } else {
      this.url = String(input);
      this.method = (init.method || "GET").toUpperCase();
      this.headers = new TinycastHeaders(init.headers);
      this.body = init.body;
    }
    const implied = bodyContentType(this.body);
    if (implied && !this.headers.has("content-type")) this.headers.set("content-type", implied);
    this.signal = init.signal;
  }
}

async function tinycastFetch(input, init = {}) {
  const request = input instanceof TinycastRequest ? input : new TinycastRequest(input, init);
  const signal = init.signal || request.signal;
  if (signal?.aborted) throw abortError();

  const raw = await hostCall("fetch", "request", [
    {
      url: request.url,
      method: request.method,
      headers: request.headers.toJSON(),
      bodyBase64: encodeBody(request.body),
    },
  ]);
  if (signal?.aborted) throw abortError();
  return new TinycastResponse(
    base64ToBytes(raw.bodyBase64 || ""),
    { status: raw.status, statusText: raw.statusText, headers: raw.headers },
    raw.url || "",
  );
}

// gaxios builds every error with `instanceof DOMException`, so a non-2xx response threw without it.
class TinycastDOMException extends Error {
  constructor(message = "", name = "Error") {
    super(String(message));
    this.name = String(name);
  }
}

if (!g.DOMException) g.DOMException = TinycastDOMException;

function abortError() {
  const error = new Error("The operation was aborted.");
  error.name = "AbortError";
  return error;
}

// `AbortSignal.timeout` aborts with TimeoutError, not AbortError — callers branch on the name.
function timeoutError() {
  const error = new Error("The operation timed out.");
  error.name = "TimeoutError";
  return error;
}

function bodyToBytes(body) {
  if (body === undefined || body === null) return null;
  if (typeof body === "string") return utf8Encode(body);
  if (body instanceof TinycastBlob) return body._bytes;
  if (body instanceof TinycastFormData) return formDataToBytes(body);
  if (body instanceof Uint8Array) return body;
  if (body instanceof ArrayBuffer) return new Uint8Array(body);
  if (ArrayBuffer.isView(body)) return new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
  if (body instanceof URLSearchParams) return utf8Encode(body.toString());
  return utf8Encode(String(body));
}

// Fetch spec: a body implies a Content-Type, which an OAuth token POST relies on rather than sets.
function bodyContentType(body) {
  if (typeof body === "string") return "text/plain;charset=UTF-8";
  if (body instanceof URLSearchParams) return "application/x-www-form-urlencoded;charset=UTF-8";
  if (body instanceof TinycastFormData) return `multipart/form-data; boundary=${body._boundary}`;
  if (body instanceof TinycastBlob) return body.type || null;
  return null;
}

function encodeBody(body) {
  const bytes = bodyToBytes(body);
  return bytes === null ? null : bytesToBase64(bytes);
}

if (!g.ReadableStream) {
  g.ReadableStream = ReadableStream;
  g.WritableStream = WritableStream;
  g.TransformStream = TransformStream;
}

if (!g.fetch) {
  g.fetch = tinycastFetch;
  g.Headers = TinycastHeaders;
  g.Response = TinycastResponse;
  g.Request = TinycastRequest;
}

// ─── AbortController ────────────────────────────────────────────────

if (!g.AbortController) {
  // node-fetch brand-checks a signal by constructor name and by tag before it will send.
  class AbortSignal {
    static name = "AbortSignal";
    constructor() {
      this.aborted = false;
      this.reason = undefined;
      this._listeners = new Set();
      this.onabort = null;
    }
    get [Symbol.toStringTag]() {
      return "AbortSignal";
    }
    addEventListener(type, listener) {
      if (type === "abort") this._listeners.add(listener);
    }
    removeEventListener(type, listener) {
      if (type === "abort") this._listeners.delete(listener);
    }
    throwIfAborted() {
      if (this.aborted) throw this.reason ?? abortError();
    }
    // The statics, not just the instance shape: a signal missing them still reads as supported at
    // the type level, so an extension calls `AbortSignal.timeout` and gets "is not a function".
    static abort(reason) {
      const signal = new AbortSignal();
      signal._fire(reason);
      return signal;
    }
    static timeout(ms) {
      const signal = new AbortSignal();
      setTimeout(() => signal._fire(timeoutError()), ms);
      return signal;
    }
    static any(signals) {
      const merged = new AbortSignal();
      for (const source of signals) {
        if (source?.aborted) {
          merged._fire(source.reason);
          break;
        }
        source?.addEventListener("abort", () => merged._fire(source.reason));
      }
      return merged;
    }
    _fire(reason) {
      if (this.aborted) return;
      this.aborted = true;
      this.reason = reason ?? abortError();
      const event = { type: "abort", target: this };
      if (typeof this.onabort === "function") this.onabort(event);
      for (const listener of this._listeners) {
        try {
          listener(event);
        } catch (error) {
          reportUncaught(error);
        }
      }
    }
  }
  g.AbortSignal = AbortSignal;
  g.AbortController = class {
    constructor() {
      this.signal = new AbortSignal();
    }
    abort(reason) {
      this.signal._fire(reason);
    }
  };
}
