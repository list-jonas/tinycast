// `util›, `querystring›, `assert›, `string_decoder› and the legacy `url› helpers.

import { Buffer } from "../buffer.js";
import { fileURLToPath, pathToFileURL, URL, URLSearchParams } from "../url.js";
import { PROMISIFY_CUSTOM } from "./common.js";
import { process } from "./process.js";

function inspect(value, depth = 2) {
  if (typeof value === "string") return `'${value}'`;
  if (typeof value === "function") return `[Function: ${value.name || "anonymous"}]`;
  if (value instanceof Error) return value.stack || String(value);
  if (value === null || typeof value !== "object") return String(value);
  if (depth < 0) return Array.isArray(value) ? "[Array]" : "[Object]";
  if (Array.isArray(value)) return `[ ${value.map((item) => inspect(item, depth - 1)).join(", ")} ]`;
  const body = Object.keys(value)
    .map((key) => `${key}: ${inspect(value[key], depth - 1)}`)
    .join(", ");
  return `{ ${body} }`;
}

function format(first, ...rest) {
  if (typeof first !== "string") return [first, ...rest].map((value) => inspect(value)).join(" ");
  let index = 0;
  const text = first.replace(/%[sdifjoO%]/g, (token) => {
    if (token === "%%") return "%";
    if (index >= rest.length) return token;
    const value = rest[index++];
    switch (token) {
      case "%s":
        return typeof value === "string" ? value : inspect(value);
      case "%d":
      case "%i":
        return String(parseInt(value, 10));
      case "%f":
        return String(parseFloat(value));
      case "%j":
        return JSON.stringify(value);
      default:
        return inspect(value);
    }
  });
  return [text, ...rest.slice(index).map((value) => inspect(value))].join(" ");
}

const TYPED_ARRAYS = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array, BigInt64Array, BigUint64Array];
const BOXED_TAGS = ["Boolean", "Number", "String", "Symbol", "BigInt"];

const tagOf = (value) => Object.prototype.toString.call(value).slice(8, -1);
const isBoxed = (value) => typeof value === "object" && value !== null && BOXED_TAGS.includes(tagOf(value));
const tagged = (tag) => (value) => tagOf(value) === tag;

/// Node's whole table: node-fetch calls `isBoxedPrimitive› on every request body it normalises.
const types = {
  isDate: (value) => value instanceof Date,
  isRegExp: (value) => value instanceof RegExp,
  isPromise: (value) => !!value && typeof value.then === "function",
  isMap: (value) => value instanceof Map,
  isSet: (value) => value instanceof Set,
  isWeakMap: (value) => value instanceof WeakMap,
  isWeakSet: (value) => value instanceof WeakSet,
  isNativeError: (value) => value instanceof Error,
  isArgumentsObject: tagged("Arguments"),
  isAsyncFunction: tagged("AsyncFunction"),
  isGeneratorFunction: tagged("GeneratorFunction"),
  isGeneratorObject: tagged("Generator"),
  isModuleNamespaceObject: tagged("Module"),
  isArrayBuffer: (value) => value instanceof ArrayBuffer,
  isSharedArrayBuffer: tagged("SharedArrayBuffer"),
  isAnyArrayBuffer: (value) => value instanceof ArrayBuffer || tagOf(value) === "SharedArrayBuffer",
  isArrayBufferView: (value) => ArrayBuffer.isView(value),
  isDataView: (value) => value instanceof DataView,
  isTypedArray: (value) => ArrayBuffer.isView(value) && !(value instanceof DataView),
  isBoxedPrimitive: isBoxed,
  isProxy: () => false,
  isExternal: () => false,
  isKeyObject: () => false,
  isCryptoKey: () => false,
  ...Object.fromEntries(TYPED_ARRAYS.map((Type) => [`is${Type.name}`, (value) => value instanceof Type])),
  ...Object.fromEntries(BOXED_TAGS.map((tag) => [`is${tag}Object`, (value) => isBoxed(value) && tagOf(value) === tag])),
};

/// Node's own ANSI matcher, verbatim: a looser regex eats printable text out of an execa message.
const VT_CONTROL = /[\u001B\u009B][[\]()#;?]*(?:(?:(?:(?:;[-a-zA-Z\d\/#&.:=?%@~_]+)*|[a-zA-Z\d]+(?:;[-a-zA-Z\d\/#&.:=?%@~_]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/g;

const sectionEnabled = (section) =>
  String(process.env.NODE_DEBUG || "")
    .split(/[\s,]+/)
    .filter(Boolean)
    .some((token) =>
      new RegExp(`^${token.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")}$`, "i").test(section),
    );

/// execa and undici both call this at module scope, so an absent `debuglog› takes the bundle down.
function debuglog(section, onLogger) {
  const enabled = sectionEnabled(section);
  const logger = enabled
    ? (...args) => process.stderr.write(`${String(section).toUpperCase()} ${process.pid}: ${format(...args)}\n`)
    : () => {};
  logger.enabled = enabled;
  onLogger?.(logger);
  return logger;
}

export const util = {
  promisify(fn) {
    if (fn[PROMISIFY_CUSTOM]) return fn[PROMISIFY_CUSTOM];
    return (...args) =>
      new Promise((resolve, reject) => {
        fn(...args, (error, value) => (error ? reject(error) : resolve(value)));
      });
  },
  callbackify(fn) {
    return (...args) => {
      const callback = args.pop();
      fn(...args).then((value) => callback(null, value), callback);
    };
  },
  inspect,
  format,
  formatWithOptions: (_options, ...args) => format(...args),
  debuglog,
  debug: debuglog,
  stripVTControlCharacters: (text) => String(text).replace(VT_CONTROL, ""),
  aborted: (signal) =>
    new Promise((resolve) => {
      if (signal.aborted) resolve();
      else signal.addEventListener("abort", () => resolve(), { once: true });
    }),
  /// More forgiving than Node's: bundles call this at load time against classes Tinycast only stubs.
  inherits(child, parent) {
    if (!child?.prototype || !parent?.prototype) return;
    Object.setPrototypeOf(child.prototype, parent.prototype);
    child.super_ = parent;
  },
  deprecate: (fn) => fn,
  isDeepStrictEqual: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  TextEncoder: globalThis.TextEncoder,
  TextDecoder: globalThis.TextDecoder,
  types,
};
util.promisify.custom = PROMISIFY_CUSTOM;
util.inspect.custom = Symbol.for("nodejs.util.inspect.custom");

export const querystring = {
  parse(text) {
    const out = {};
    for (const [key, value] of new URLSearchParams(String(text || "").replace(/^[?]/, ""))) {
      if (out[key] === undefined) out[key] = value;
      else if (Array.isArray(out[key])) out[key].push(value);
      else out[key] = [out[key], value];
    }
    return out;
  },
  stringify(object) {
    const params = new URLSearchParams();
    for (const key of Object.keys(object || {})) {
      const value = object[key];
      if (Array.isArray(value)) for (const item of value) params.append(key, item);
      else params.append(key, value);
    }
    return params.toString();
  },
  escape: encodeURIComponent,
  unescape: decodeURIComponent,
};

/// Node's legacy `url.format›, which also takes the parts object http-cookie-agent builds per request.
function formatURL(value) {
  if (typeof value !== "object" || value === null || value instanceof URL) return String(value);
  const protocol = value.protocol ? value.protocol.replace(/:?$/, ":") : "";
  const slashes = value.slashes || /^(https?|ftp|gopher|file|wss?):$/.test(protocol) ? "//" : "";
  const auth = value.auth ? `${value.auth}@` : "";
  const host = value.host ?? (value.hostname ? value.hostname + (value.port ? `:${value.port}` : "") : "");
  const pathname = (value.pathname ?? "").replace(/[?#]/g, encodeURIComponent);
  const query = value.query && typeof value.query === "object" ? querystring.stringify(value.query) : "";
  const search = value.search ?? (query ? `?${query}` : "");
  return `${protocol}${slashes}${auth}${host}${pathname}${search}${value.hash ?? ""}`;
}

// node-fetch spreads a parsed URL into its request options and reads the legacy `path› off it.
function parseURL(text) {
  const url = new URL(text);
  return Object.assign(url, { path: url.pathname + url.search });
}

export const urlModule = {
  URL,
  URLSearchParams,
  fileURLToPath,
  pathToFileURL,
  parse: parseURL,
  format: formatURL,
  resolve: (from, to) => new URL(to, from).href,
};

export function assert(value, message) {
  if (!value) throw new Error(message || "Assertion failed");
}
assert.ok = assert;
assert.equal = (a, b, message) => assert(a == b, message || `${a} != ${b}`);
assert.strictEqual = (a, b, message) => assert(a === b, message || `${a} !== ${b}`);
assert.notStrictEqual = (a, b, message) => assert(a !== b, message || `${a} === ${b}`);
assert.deepStrictEqual = (a, b, message) =>
  assert(JSON.stringify(a) === JSON.stringify(b), message || "not deeply equal");
assert.fail = (message) => assert(false, message);
assert.throws = (fn, message) => {
  try {
    fn();
  } catch {
    return;
  }
  assert(false, message || "Missing expected exception");
};

export class StringDecoder {
  constructor(encoding = "utf8") {
    this.encoding = encoding;
  }
  write(bytes) {
    return Buffer.from(bytes).toString(this.encoding);
  }
  end(bytes) {
    return bytes ? this.write(bytes) : "";
  }
}
