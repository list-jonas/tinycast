// Node's `http` / `https`, backed by the same URLSession bridge `fetch` uses. `node-fetch` is
// bundled into a large share of extensions and reaches the network only through `request()`, so
// without this the whole library resolves and then fails on its first call.

import { hostCall } from "./host.js";
import { Buffer } from "./buffer.js";
import { base64ToBytes, bytesToBase64 } from "./polyfills.js";
import { Readable, Writable } from "./stream.js";

const HTTP_TOKEN = /^[\^`\-\w!#$%&'*+.|~]+$/;

export function validateHeaderName(name) {
  if (HTTP_TOKEN.test(String(name))) return;
  const error = new TypeError(`Header name must be a valid HTTP token [${name}]`);
  error.code = "ERR_INVALID_HTTP_TOKEN";
  throw error;
}

export function validateHeaderValue(name, value) {
  if (!/[^\t\u0020-\u007E\u0080-\u00FF]/.test(String(value))) return;
  const error = new TypeError(`Invalid character in header content ["${name}"]`);
  error.code = "ERR_INVALID_CHAR";
  throw error;
}

class IncomingMessage extends Readable {
  constructor(raw) {
    super();
    this.statusCode = raw.status;
    this.statusMessage = raw.statusText || "";
    this.httpVersion = "1.1";
    this.complete = true;
    this.headers = responseHeaders(raw.headers);
    this.rawHeaders = Object.entries(this.headers).flat();
    this.url = raw.url || "";
    this.socket = null;
  }
  setTimeout() {
    return this;
  }
}

/// The body is sent when the caller ends the request, which is what makes a `Writable` the right
/// shape: `node-fetch` pipes a stream body straight into this and lets the pipe call `end`.
class ClientRequest extends Writable {
  constructor(url, options) {
    super();
    this.url = url;
    this.method = (options.method || "GET").toUpperCase();
    this.headers = { ...(options.headers ?? {}) };
    this.aborted = false;
    this._chunks = [];
    this._timeout = null;
    if (options.timeout) this.setTimeout(options.timeout);
  }

  setHeader(name, value) {
    this.headers[name] = value;
    return this;
  }
  getHeader(name) {
    return this.headers[name];
  }
  removeHeader(name) {
    delete this.headers[name];
  }
  flushHeaders() {}
  // A real deadline, not a no-op: `node-fetch` passes its `timeout` here and reports the request as
  // hung forever otherwise, since nothing cancels the URLSession task across the bridge.
  setTimeout(ms, callback) {
    if (callback) this.on("timeout", callback);
    clearTimeout(this._timeout);
    this._timeout = setTimeout(() => this._expire(), ms);
    return this;
  }
  setNoDelay() {}
  setSocketKeepAlive() {}

  _write(chunk, encoding, callback) {
    const bytes = typeof chunk === "string" ? Buffer.from(chunk, encoding || "utf8") : Buffer.from(chunk);
    this._chunks.push(bytes);
    callback();
  }

  _final(callback) {
    callback();
    this._send();
  }

  abort() {
    this.aborted = true;
    clearTimeout(this._timeout);
  }
  destroy() {
    this.aborted = true;
    clearTimeout(this._timeout);
    return this;
  }

  /// Node emits `timeout` and leaves aborting to the caller, but nothing here can cancel the task —
  /// so the request is abandoned as well, or a listenerless caller would wait on it forever.
  _expire() {
    if (this.aborted) return;
    this.emit("timeout");
    this.aborted = true;
    const error = new Error(`Request to ${this.url} timed out`);
    error.code = "ETIMEDOUT";
    this.emit("error", error);
  }

  _send() {
    const body = this._chunks.length ? bytesToBase64(Buffer.concat(this._chunks)) : null;
    hostCall("fetch", "request", [
      { url: this.url, method: this.method, headers: normalizeHeaders(this.headers), bodyBase64: body },
    ]).then(
      (raw) => {
        if (this.aborted) return;
        clearTimeout(this._timeout);
        const message = new IncomingMessage(raw);
        const bytes = base64ToBytes(raw.bodyBase64 || "");
        // The decoded length is the one a caller can trust; the encoded one describes bytes that
        // never arrive, and dropping it outright loses a header `content-length`-driven code reads.
        message.headers["content-length"] = String(bytes.length);
        message.rawHeaders = Object.entries(message.headers).flat();
        this.emit("response", message);
        // Push after the handler runs: it attaches its reader synchronously, and a body delivered
        // before that would be buffered against a consumer that never arrives.
        queueMicrotask(() => {
          if (bytes.length) message.push(Buffer.from(bytes));
          message.push(null);
        });
      },
      (error) => {
        clearTimeout(this._timeout);
        if (!this.aborted) this.emit("error", error);
      },
    );
  }
}

// URLSession decodes the body, so `content-encoding` describes bytes a caller never sees and
// `node-fetch` would gunzip already-plain text. `content-length` is restored from what arrived.
const DECODED_AWAY_HEADERS = new Set(["content-encoding", "content-length"]);

function responseHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers ?? {})) {
    if (!DECODED_AWAY_HEADERS.has(name.toLowerCase())) out[name] = value;
  }
  return out;
}

function normalizeHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers ?? {})) {
    if (value === undefined || value === null) continue;
    out[name] = Array.isArray(value) ? value.join(", ") : String(value);
  }
  return out;
}

function requestURL(input, options) {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.toString();
  const protocol = options.protocol || input.protocol || "https:";
  // `hostname` first: `host` carries the port too, and appending `port` after it would repeat it.
  const named = options.hostname || options.host || input.hostname || input.host || "localhost";
  const host = String(named).replace(/:\d+$/, "");
  const port = options.port ?? input.port;
  const target = pathOf(options) || pathOf(input) || "/";
  return `${protocol}//${host}${port ? `:${port}` : ""}${target}`;
}

/// A spread of this runtime's `URL` — what `node-fetch` passes — carries no `path`, since `host` and
/// `search` are prototype getters that an `Object.assign` never copies. Rebuild it from `pathname`.
function pathOf(source) {
  if (source.path) return source.path;
  if (!source.pathname) return "";
  // `searchParams` is an own property, so it survives the copy that drops the `search` getter.
  const query = source.search ?? (source.searchParams ? `?${source.searchParams}` : "");
  return `${source.pathname}${query === "?" ? "" : query}`;
}

function request(input, options, callback) {
  if (typeof options === "function") {
    callback = options;
    options = {};
  }
  const fromInput = typeof input === "object" && !(input instanceof URL) ? input : {};
  const settings = { ...fromInput, ...(options ?? {}) };
  const call = new ClientRequest(requestURL(input, settings), settings);
  if (callback) call.on("response", callback);
  return call;
}

function get(input, options, callback) {
  const call = request(input, options, callback);
  call.end();
  return call;
}

function makeHttpModule(protocol) {
  const module = {
    request: (input, options, callback) => request(input, options, callback),
    get,
    validateHeaderName,
    validateHeaderValue,
    globalAgent: {},
    Agent: class {
      constructor(options) {
        Object.assign(this, options ?? {});
      }
      destroy() {}
    },
    IncomingMessage,
    ClientRequest,
    STATUS_CODES: {},
    METHODS: ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"],
    protocol,
    createServer() {
      throw new Error("http.createServer is not supported in Tinycast extensions (no server runtime).");
    },
  };
  module.default = module;
  return module;
}

export const httpModule = makeHttpModule("http:");
export const httpsModule = makeHttpModule("https:");
