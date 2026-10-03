// Node built-ins that extension bundles keep external. Everything filesystem-, process- or
// crypto-shaped is a synchronous host call; the socket-shaped modules resolve but throw on use.

import { Buffer, bufferModule } from "./buffer.js";
import { EventEmitter } from "./events.js";
import { reportUncaught } from "./host.js";
import { Duplex, PassThrough, Readable, Stream, Transform, Writable, finished, finishedPromise, pipeline, pipelinePromise } from "./streams.js";
import { ReadableStream, TransformStream, WritableStream } from "./web-streams.js";
import { punycode } from "./punycode.js";
import { dgram } from "./dgram.js";
import { childProcess } from "./node/child-process.js";
import { cryptoModule, zlib } from "./node/crypto.js";
import { fs, fsPromises } from "./node/fs.js";
import { httpModule } from "./node/http.js";
import { os, path, process } from "./node/process.js";
import { unsupportedModule } from "./node/unsupported.js";
import { assert, querystring, StringDecoder, urlModule, util } from "./node/util.js";

export { configureNodeShims } from "./node/process.js";

/// Node's streams are ES5 functions: follow-redirects, inside axios, calls `Writable› on its `this›.
function es5Constructible(Class) {
  return new Proxy(Class, {
    apply: (target, self, args) =>
      void Object.defineProperties(self, Object.getOwnPropertyDescriptors(new target(...args))),
  });
}

const streamClasses = Object.fromEntries(
  Object.entries({ Stream, Readable, Writable, Duplex, Transform, PassThrough }).map(([name, Class]) => [name, es5Constructible(Class)]),
);
const streamPromises = { pipeline: (...stages) => pipelinePromise(stages), finished: finishedPromise };

const streamModule = unsupportedModule(
  "stream",
  Object.assign(streamClasses.Stream, {
    ...streamClasses,
    getDefaultHighWaterMark: (objectMode) => (objectMode ? 16 : 16 * 1024),
    pipeline,
    finished,
    promises: streamPromises,
  }),
);

/// http2-wrapper reads `new tls.TLSSocket(stream)._handle._parentWrap.constructor› at import time.
const TLSSocket = class TLSSocket extends Duplex {
  _handle = { _parentWrap: { constructor: TLSSocket } };
};

class AsyncLocalStorage {
  run(_store, fn) {
    return fn();
  }
  getStore() {
    return undefined;
  }
}

/// undici extends this at module scope; with one synchronous context, the scope is just the call.
class AsyncResource {
  constructor(type) {
    this.type = type;
  }
  runInAsyncScope(fn, thisArg, ...args) {
    return Reflect.apply(fn, thisArg, args);
  }
  bind(fn, thisArg = this) {
    return fn.bind(thisArg);
  }
  emitDestroy() {
    return this;
  }
  asyncId() {
    return 0;
  }
  triggerAsyncId() {
    return 0;
  }
}

/// undici opens a channel per instrumentation point at module scope, so `channel› cannot refuse.
class Channel {
  constructor(name) {
    this.name = name;
    this._subscribers = [];
  }
  get hasSubscribers() {
    return this._subscribers.length > 0;
  }
  subscribe(onMessage) {
    this._subscribers.push(onMessage);
  }
  unsubscribe(onMessage) {
    const index = this._subscribers.indexOf(onMessage);
    if (index === -1) return false;
    this._subscribers.splice(index, 1);
    return true;
  }
  publish(message) {
    for (const onMessage of [...this._subscribers]) {
      try {
        onMessage(message, this.name);
      } catch (error) {
        reportUncaught(error);
      }
    }
  }
  bindStore() {}
  unbindStore() {
    return false;
  }
  runStores(message, fn, thisArg, ...args) {
    this.publish(message);
    return Reflect.apply(fn, thisArg, args);
  }
}

const channels = new Map();

function channel(name) {
  if (!channels.has(name)) channels.set(name, new Channel(name));
  return channels.get(name);
}

const diagnosticsChannel = unsupportedModule("diagnostics_channel", {
  Channel,
  channel,
  hasSubscribers: (name) => channels.get(name)?.hasSubscribers ?? false,
  subscribe: (name, onMessage) => channel(name).subscribe(onMessage),
  unsubscribe: (name, onMessage) => channels.get(name)?.unsubscribe(onMessage) ?? false,
});

const dns = unsupportedModule("dns");
const readline = unsupportedModule("readline");

export const nodeModules = {
  path,
  "path/posix": path,
  "path/win32": path,
  os,
  fs,
  "fs/promises": fsPromises,
  child_process: childProcess,
  crypto: cryptoModule,
  zlib,
  events: EventEmitter,
  util,
  "util/types": util.types,
  buffer: bufferModule,
  process,
  querystring,
  punycode,
  assert,
  "assert/strict": assert,
  string_decoder: { StringDecoder },
  url: urlModule,
  timers: { setTimeout, clearTimeout, setInterval, clearInterval, setImmediate, clearImmediate },
  "timers/promises": { setTimeout: (ms, value) => new Promise((resolve) => setTimeout(() => resolve(value), ms)) },
  perf_hooks: { performance: globalThis.performance },
  http: httpModule("http"),
  https: httpModule("https"),
  dgram,
  net: unsupportedModule("net"),
  tls: unsupportedModule("tls", { TLSSocket }),
  dns,
  "dns/promises": dns,
  stream: streamModule,
  "stream/web": { ReadableStream, WritableStream, TransformStream },
  "stream/promises": streamPromises,
  // No-ops rather than refusals: undici's `markAsUncloneable || (() => {})› never falls back.
  worker_threads: unsupportedModule("worker_threads", {
    isMainThread: true,
    markAsUncloneable: () => {},
    markAsUntransferable: () => {},
    isMarkedAsUntransferable: () => false,
  }),
  readline,
  "readline/promises": readline,
  tty: { isatty: () => false },
  vm: unsupportedModule("vm"),
  module: { createRequire: () => requireStub, builtinModules: [] },
  constants: {},
  cluster: { isPrimary: true, isMaster: true },
  inspector: {},
  v8: {},
  async_hooks: { AsyncLocalStorage, AsyncResource },
  diagnostics_channel: diagnosticsChannel,
  console: globalThis.console,
};

function requireStub(name) {
  throw new Error(`createRequire is not supported in Tinycast extensions (tried to load "${name}").`);
}

for (const name of [
  "domain", "http2", "inspector/promises", "repl", "stream/consumers", "sys", "trace_events", "wasi", "sea",
  "sqlite", "test", "test/reporters",
]) {
  nodeModules[name] = unsupportedModule(name);
}

// Node builtins are addressable with and without the `node:› prefix.
for (const name of Object.keys(nodeModules)) {
  nodeModules[`node:${name}`] = nodeModules[name];
}

globalThis.process = process;
globalThis.Buffer = Buffer;
globalThis.global = globalThis;

