// Globals JavaScriptCore doesn't ship that extension bundles (and React's scheduler) assume.

import { hostRaw, log, reportUncaught } from "./host.js";
import { base64ToBytes, bytesToBase64, codeUnitsToString, utf8Decode, utf8Encode } from "./bytes.js";
import "./fetch.js";
import "./dom-events.js";

const g = globalThis;

if (!g.console) g.console = {};
for (const level of ["log", "info", "warn", "error", "debug", "trace"]) {
  g.console[level] = (...args) => log(level === "debug" || level === "trace" ? "log" : level, args);
}
// Extensions occasionally call these; make them harmless instead of a TypeError.
for (const noop of ["group", "groupEnd", "table", "time", "timeEnd", "dir", "assert", "count"]) {
  if (!g.console[noop]) g.console[noop] = () => {};
}

if (!g.performance) g.performance = { now: () => Date.now() };
else if (!g.performance.now) g.performance.now = () => Date.now();

// ─── Timers ─────────────────────────────────────────────────────────
// Swift owns the clock: it schedules on its runloop and calls back into `fireTimer`.

let nextTimerId = 1;
const timers = new Map();

function schedule(callback, delay, repeats, args) {
  if (typeof callback !== "function") return 0;
  const id = nextTimerId++;
  timers.set(id, { callback, args, repeats });
  hostRaw.startTimer(String(id), Math.max(0, Number(delay) || 0), repeats);
  return id;
}

function unschedule(id) {
  const key = Number(id);
  if (!timers.has(key)) return;
  timers.delete(key);
  hostRaw.clearTimer(String(key));
}

export function fireTimer(id) {
  const key = Number(id);
  const timer = timers.get(key);
  if (!timer) return;
  if (!timer.repeats) timers.delete(key);
  try {
    timer.callback(...timer.args);
  } catch (error) {
    reportUncaught(error);
  }
}

g.setTimeout = (cb, delay, ...args) => schedule(cb, delay, false, args);
g.setInterval = (cb, delay, ...args) => schedule(cb, delay, true, args);
g.clearTimeout = unschedule;
g.clearInterval = unschedule;
// Node's immediate/tick APIs, used by bundled deps.
g.setImmediate = (cb, ...args) => schedule(cb, 0, false, args);
g.clearImmediate = unschedule;

if (!g.queueMicrotask) {
  const resolved = Promise.resolve();
  g.queueMicrotask = (cb) => {
    resolved.then(cb).catch(reportUncaught);
  };
}

// ─── WebAssembly ────────────────────────────────────────────────────
// JSC settles the promise forms on a run loop the JS queue never spins; constructors don't wait.

if (g.WebAssembly) {
  const { Module, Instance } = g.WebAssembly;
  const compile = (bytes) => new Promise((resolve) => resolve(new Module(bytes)));
  const instantiate = (source, imports) =>
    new Promise((resolve) => {
      if (source instanceof Module) {
        resolve(new Instance(source, imports));
        return;
      }
      const module = new Module(source);
      resolve({ module, instance: new Instance(module, imports) });
    });
  const bytesOf = async (source) => new Uint8Array(await (await source).arrayBuffer());
  g.WebAssembly.compile = compile;
  g.WebAssembly.instantiate = instantiate;
  g.WebAssembly.compileStreaming = async (source) => compile(await bytesOf(source));
  g.WebAssembly.instantiateStreaming = async (source, imports) =>
    instantiate(await bytesOf(source), imports);
}

// ─── Text encoding / base64 ─────────────────────────────────────────

if (!g.atob) g.atob = (text) => codeUnitsToString(base64ToBytes(text));
if (!g.btoa) {
  g.btoa = (text) => {
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
    return bytesToBase64(bytes);
  };
}

if (!g.structuredClone) {
  g.structuredClone = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));
}

// JavaScriptCore has no TextEncoder/TextDecoder (they're WebCore APIs), and bundled deps reach for
// them freely. Only the UTF-8 path is real; an exotic requested encoding decodes as UTF-8.
if (!g.TextEncoder) {
  g.TextEncoder = class TextEncoder {
    get encoding() {
      return "utf-8";
    }
    encode(text = "") {
      return utf8Encode(String(text));
    }
    encodeInto(text, target) {
      const bytes = utf8Encode(String(text));
      const written = Math.min(bytes.length, target.length);
      target.set(bytes.subarray(0, written));
      return { read: text.length, written };
    }
  };
}

if (!g.TextDecoder) {
  g.TextDecoder = class TextDecoder {
    constructor(encoding = "utf-8", options = {}) {
      this.encoding = String(encoding).toLowerCase();
      this.fatal = !!options.fatal;
      this.ignoreBOM = !!options.ignoreBOM;
    }
    decode(input) {
      if (input === undefined) return "";
      let bytes;
      if (input instanceof Uint8Array) bytes = input;
      else if (input instanceof ArrayBuffer) bytes = new Uint8Array(input);
      else if (ArrayBuffer.isView(input))
        bytes = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      else throw new TypeError("TextDecoder.decode: unsupported input");
      if (!this.ignoreBOM && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
        bytes = bytes.subarray(3);
      }
      return utf8Decode(bytes);
    }
  };
}
