// `http›/`https›. Bundles ship their own HTTP client — node-fetch travels inside `@raycast/utils› — and
// drive `http.request›: one request, buffered both ways, over the URLSession bridge `fetch› uses.

import { hostCall } from "../host.js";
import { Buffer } from "../buffer.js";
import { EventEmitter } from "../events.js";
import { PassThrough } from "../streams.js";
import { URL } from "../url.js";
import { upgradeToWebSocket } from "../websocket.js";
import { codedError } from "./common.js";
import { Hash } from "./crypto.js";
import { unsupportedModule } from "./unsupported.js";

/// A comma that starts another `name=› — never the one inside an `Expires› date.
const SET_COOKIE_BOUNDARY = /,\s*(?=[^;,=\s]+=)/;
const HEADER_TOKEN = /^[\^`\-\w!#$%&'*+.|~]+$/;
const HEADER_VALUE = /[^\t\u0020-\u007e\u0080-\u00ff]/;
const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// URLSession writes the handshake itself; forwarding these would have it refuse the request.
const HANDSHAKE_HEADERS = new Set([
  "connection", "upgrade", "host", "sec-websocket-key", "sec-websocket-version",
  "sec-websocket-extensions", "sec-websocket-protocol",
]);

class IncomingMessage extends PassThrough {
  constructor(raw) {
    super();
    this.statusCode = raw.status ?? 200;
    this.statusMessage = raw.statusText ?? "";
    this.httpVersion = "1.1";
    this.url = raw.url ?? "";
    this.complete = true;
    // The bridge decodes the body itself, so keeping these would have the client gunzip plaintext.
    this.headers = Object.fromEntries(
      Object.entries(raw.headers ?? {}).filter(
        ([name]) => name !== "content-encoding" && name !== "content-length",
      ),
    );
    // URLSession folds repeated `Set-Cookie› headers into one line; Node always hands out an array.
    if (typeof this.headers["set-cookie"] === "string") {
      this.headers["set-cookie"] = this.headers["set-cookie"].split(SET_COOKIE_BOUNDARY);
    }
    this.rawHeaders = Object.entries(this.headers).flatMap(([name, value]) =>
      [value].flat().flatMap((item) => [name, item]),
    );
  }
}

function validateHeaderName(name) {
  if (typeof name !== "string" || !HEADER_TOKEN.test(name)) {
    throw codedError(`Header name must be a valid HTTP token ["${name}"]`, "ERR_INVALID_HTTP_TOKEN", TypeError);
  }
}

function validateHeaderValue(name, value) {
  if (value === undefined) {
    throw codedError(`Invalid value "undefined" for header "${name}"`, "ERR_HTTP_INVALID_HEADER_VALUE", TypeError);
  }
  if (HEADER_VALUE.test(String(value))) {
    throw codedError(`Invalid character in header content ["${name}"]`, "ERR_INVALID_CHAR", TypeError);
  }
}

/// The bridge owns every socket; `addRequest› is only a hook for cookie agents to override.
class Agent extends EventEmitter {
  constructor(options) {
    super();
    this.options = { ...options };
  }
  addRequest() {}
  destroy() {}
}

class ClientRequest extends EventEmitter {
  constructor(url, options, callback) {
    super();
    this.url = url;
    // A malformed URL still fails the way it always has: as an `error› once the bridge rejects it.
    if (URL.canParse(url)) {
      const target = new URL(url);
      this.protocol = target.protocol;
      this.host = target.hostname;
      this.path = target.pathname + target.search;
    }
    this.method = String(options.method ?? "GET").toUpperCase();
    this.writable = true;
    this.writableEnded = false;
    this._headers = new Map();
    this._chunks = [];
    this._destroyed = false;
    for (const [name, value] of Object.entries(options.headers ?? {})) this.setHeader(name, value);
    if (callback) this.once("response", callback);
    // Any other agent shape — agent-base 6 extends EventEmitter — would try to open a socket.
    if (options.agent instanceof Agent) options.agent.addRequest(this, options);
  }

  /// Node's last chance to touch headers before they go out; cookie agents wrap it.
  _implicitHeader() {}

  setHeader(name, value) {
    this._headers.set(String(name).toLowerCase(), Array.isArray(value) ? value.join(", ") : String(value));
    return this;
  }
  getHeader(name) {
    return this._headers.get(String(name).toLowerCase());
  }
  getHeaders() {
    return Object.fromEntries(this._headers);
  }
  removeHeader(name) {
    this._headers.delete(String(name).toLowerCase());
  }

  write(chunk) {
    this._chunks.push(Buffer.from(chunk));
    return true;
  }

  end(chunk) {
    if (chunk !== undefined && chunk !== null) this.write(chunk);
    this._implicitHeader();
    this.writableEnded = true;
    this._send();
    return this;
  }

  abort() {
    return this.destroy();
  }

  destroy(error) {
    this._destroyed = true;
    clearTimeout(this._timer);
    if (error) this.emit("error", error);
    return this;
  }

  setTimeout(ms, callback) {
    if (callback) this.once("timeout", callback);
    clearTimeout(this._timer);
    this._timer = setTimeout(() => this.emit("timeout"), ms);
    return this;
  }

  setNoDelay() {
    return this;
  }
  setSocketKeepAlive() {
    return this;
  }
  flushHeaders() {}

  _failed(error) {
    clearTimeout(this._timer);
    if (!this._destroyed) this.emit("error", error instanceof Error ? error : new Error(String(error)));
  }

  async _send() {
    if (String(this.getHeader("upgrade") ?? "").toLowerCase() === "websocket") return this._upgrade();
    // Content negotiation belongs to the transport, which decodes for us and reports the result.
    this.removeHeader("accept-encoding");
    const body = this._chunks.length ? Buffer.concat(this._chunks) : null;
    try {
      const raw = await hostCall("fetch", "request", [
        {
          url: this.url,
          method: this.method,
          headers: this.getHeaders(),
          bodyBase64: body === null ? null : body.toString("base64"),
        },
      ]);
      if (this._destroyed) return;
      clearTimeout(this._timer);
      const response = new IncomingMessage(raw);
      this.emit("response", response);
      response.end(Buffer.from(raw.bodyBase64 ?? "", "base64"));
      this.emit("close");
    } catch (error) {
      this._failed(error);
    }
  }

  /// The host opens the socket, so the 101 is synthesised — never with an extension, so no deflate.
  async _upgrade() {
    const headers = this.getHeaders();
    try {
      const { socket, protocol } = await upgradeToWebSocket({
        url: this.url.replace(/^http/, "ws"),
        protocols: String(headers["sec-websocket-protocol"] ?? "").split(",").map((item) => item.trim()).filter(Boolean),
        headers: Object.fromEntries(Object.entries(headers).filter(([name]) => !HANDSHAKE_HEADERS.has(name))),
      });
      clearTimeout(this._timer);
      if (this._destroyed) return socket.destroy();
      const accept = new Hash("sha1").update(`${headers["sec-websocket-key"] ?? ""}${WEBSOCKET_GUID}`).digest("base64");
      const response = new IncomingMessage({
        status: 101,
        statusText: "Switching Protocols",
        headers: {
          upgrade: "websocket",
          connection: "Upgrade",
          "sec-websocket-accept": accept,
          ...(protocol ? { "sec-websocket-protocol": protocol } : {}),
        },
      });
      if (!this.emit("upgrade", response, socket, Buffer.alloc(0))) socket.destroy();
    } catch (error) {
      this._failed(error);
    }
  }
}

function httpRequest(input, options, callback, scheme) {
  if (typeof options === "function") return httpRequest(input, {}, options, scheme);
  if (typeof input === "string" || input instanceof URL) {
    return new ClientRequest(String(input), options ?? {}, callback);
  }
  const spec = input ?? {};
  const host = spec.hostname ?? spec.host ?? "localhost";
  const port = spec.port ? `:${spec.port}` : "";
  return new ClientRequest(`${spec.protocol ?? scheme}//${host}${port}${spec.path ?? "/"}`, spec, callback);
}

export const httpModule = (name) =>
  unsupportedModule(name, {
    // The scheme rides with the module: `ws› and axios both pass an options bag with no protocol.
    request: (input, options, callback) => httpRequest(input, options, callback, `${name}:`),
    get: (input, options, callback) => httpRequest(input, options, callback, `${name}:`).end(),
    validateHeaderName,
    validateHeaderValue,
    IncomingMessage,
    ClientRequest,
    Agent,
    globalAgent: new Agent(),
    STATUS_CODES: {},
    METHODS: [],
  });

