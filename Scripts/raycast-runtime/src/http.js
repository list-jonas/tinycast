// Node's `http` / `https`, backed by the same URLSession bridge `fetch` uses. `node-fetch` is
// bundled into a large share of extensions and reaches the network only through `request()`, so
// without this the whole library resolves and then fails on its first call.

import { hostCall } from "./host.js";
import { Buffer } from "./buffer.js";
import { base64ToBytes, bytesToBase64 } from "./polyfills.js";
import { Readable, Writable } from "./stream.js";
import { EventEmitter } from "./events.js";

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
    // The one header Node never folds, because a site sets several and each is its own cookie. The
    // bridge sends them already split, since joining them is what makes an `Expires` comma ambiguous.
    if (raw.setCookie?.length) this.headers["set-cookie"] = raw.setCookie;
    this.rawHeaders = rawHeaderPairs(this.headers);
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
    this._deadline = null;
    this._sent = false;
    this._socket = new EventEmitter();
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
  // Armed at send rather than here, the way Node arms it on socket assignment: a request whose body
  // is written a chunk at a time would otherwise spend its whole budget before a byte leaves, and one
  // that is built and never sent would fail on a deadline it was never actually racing.
  setTimeout(ms, callback) {
    if (callback) this.on("timeout", callback);
    this._deadline = ms;
    if (this._sent) this._arm();
    return this;
  }
  setNoDelay() {}
  setSocketKeepAlive() {}

  _arm() {
    clearTimeout(this._timeout);
    if (this._deadline != null) this._timeout = setTimeout(() => this._expire(), this._deadline);
  }

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

  /// A reply the HTTP spec gives no body: its `content-length` describes what a GET would have
  /// returned, so it is the one header the decoded length must not overwrite.
  _bodiless(status) {
    return this.method === "HEAD" || status === 204 || status === 304;
  }

  _send() {
    const body = this._chunks.length ? bytesToBase64(Buffer.concat(this._chunks)) : null;
    // The deadline starts here, where Node's starts: this is the moment the request is actually
    // in flight, and the only stretch a `timeout` was ever meant to bound.
    this._sent = true;
    this._arm();
    // `node-fetch` v2 arms its `timeout` inside `once("socket")` and never anywhere else, so a
    // request that reports no socket silently loses the deadline the caller asked for. There is no
    // socket to hand over — the stand-in only has to carry `listenerCount`, which its own
    // chunked-ending guard calls on whatever arrives.
    queueMicrotask(() => this.emit("socket", this._socket));
    hostCall("fetch", "request", [
      {
        url: this.url,
        method: this.method,
        headers: normalizeHeaders(this.headers),
        bodyBase64: body,
        // Node hands a 3xx straight back; whatever sits above this implements its own hop rules,
        // and following here would take `redirect`, `follow` and `max-redirect` away from it.
        redirect: "manual",
      },
    ]).then(
      (raw) => {
        if (this.aborted) return;
        clearTimeout(this._timeout);
        const message = new IncomingMessage(raw);
        const bytes = base64ToBytes(raw.bodyBase64 || "");
        // The decoded length is the one a caller can trust; the encoded one describes bytes that
        // never arrive, and dropping it outright loses a header `content-length`-driven code reads.
        // A bodiless reply is the exception — its length describes the body a GET would have got —
        // so the server's own value is put back rather than measuring the nothing that arrived.
        message.headers["content-length"] = this._bodiless(message.statusCode)
          ? String(raw.headers?.["content-length"] ?? bytes.length)
          : String(bytes.length);
        message.rawHeaders = rawHeaderPairs(message.headers);
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

/// Node's flat name/value list, where a header holding several values contributes one pair each —
/// flattening the array itself would splice its entries in as if they were names.
function rawHeaderPairs(headers) {
  const pairs = [];
  for (const [name, value] of Object.entries(headers)) {
    for (const single of Array.isArray(value) ? value : [value]) pairs.push(name, single);
  }
  return pairs;
}

function normalizeHeaders(headers) {
  const out = {};
  for (const [name, value] of Object.entries(headers ?? {})) {
    if (value === undefined || value === null) continue;
    out[name] = Array.isArray(value) ? value.join(", ") : String(value);
  }
  return out;
}

// `hostname` and a bracketed IPv6 literal carry no port; `host` does, and it has to be split off
// rather than appended after, or a `{ host, port }` pair would name the port twice.
const HOST_WITH_PORT = /^(\[[^\]]*\]|[^:]*):(\d+)$/;

function requestURL(input, options, fallbackProtocol) {
  if (typeof input === "string") return input;
  if (input instanceof URL) return input.toString();
  // The calling module's own scheme is the fallback: an `http.request` that defaulted to https
  // would quietly retarget every plain-options call, which is how localhost tooling is reached.
  const protocol = options.protocol || input.protocol || fallbackProtocol;
  const named = String(options.hostname || options.host || input.hostname || input.host || "localhost");
  const [, host = named, embeddedPort] = HOST_WITH_PORT.exec(named) ?? [];
  const port = options.port ?? input.port ?? embeddedPort;
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

function request(input, options, callback, fallbackProtocol) {
  if (typeof options === "function") {
    callback = options;
    options = {};
  }
  const fromInput = typeof input === "object" && !(input instanceof URL) ? input : {};
  const settings = { ...fromInput, ...(options ?? {}) };
  const call = new ClientRequest(requestURL(input, settings, fallbackProtocol), settings);
  if (callback) call.on("response", callback);
  return call;
}

function makeHttpModule(protocol) {
  const module = {
    request: (input, options, callback) => request(input, options, callback, protocol),
    get: (input, options, callback) => request(input, options, callback, protocol).end(),
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
