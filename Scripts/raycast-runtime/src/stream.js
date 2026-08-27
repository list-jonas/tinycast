// Node's `stream`. Real rather than a stub because every bundled HTTP client is built on it:
// `node-fetch` type-checks bodies with `body instanceof Stream`, pipes a response through a
// `PassThrough` and then consumes it by async iteration, so a throwing member is never reached —
// the bundle dies on the type check first, far from the call the user made.

import { EventEmitter } from "./events.js";
import { Buffer } from "./buffer.js";
import { RESERVED_MEMBERS } from "./interop.js";

export class Stream extends EventEmitter {
  pipe(destination, options) {
    this.on("data", (chunk) => destination.write?.(chunk));
    this.on("end", () => {
      if (options?.end !== false) destination.end?.();
    });
    return destination;
  }

  /// Node closes a stream once; a Duplex reaches this from both halves, so the second one is dropped.
  _emitClose() {
    if (this._closed) return;
    this._closed = true;
    this.emit("close");
  }

  /// Deferred like Node, error or not: `stream.destroy()` on one line and `.on("close", …)` on the
  /// next is the shape callers write, so a synchronous emit lands before that listener exists.
  /// `close` trails `error` in the same turn — a `close` that overtook it reports a premature close.
  _failAndClose(error) {
    queueMicrotask(() => {
      if (error) this.emit("error", error);
      this._emitClose();
    });
  }

  /// On the shared base rather than `Writable`: a `Duplex` borrows `Writable`'s `write`/`end` by
  /// call, but extends `Readable`, so anything those two reach through `this` has to live here or
  /// it is missing on exactly the streams a pipe is built from.
  /// Deferred like every other stream failure, so a handler attached on the next line still sees it;
  /// the callback form is answered too, since that is what a piping stage reads.
  _failWriteAfterEnd(callback) {
    const error = new Error("write after end");
    error.code = "ERR_STREAM_WRITE_AFTER_END";
    queueMicrotask(() => {
      callback?.(error);
      this.emit("error", error);
    });
    return false;
  }
}

export class Readable extends Stream {
  constructor(options = {}) {
    super();
    this.readable = true;
    this.readableEnded = false;
    this.destroyed = false;
    this._closed = false;
    this._endEmitted = false;
    this._queue = [];
    this._encoding = null;
    this._flowing = false;
    this._ended = false;
    this._failure = null;
    this._waiters = [];
    if (typeof options.read === "function") this._read = options.read;
  }

  /// A source with nothing to pull from: everything this runtime streams is pushed in whole.
  _read() {}

  setEncoding(encoding) {
    this._encoding = encoding;
    return this;
  }

  push(chunk) {
    // Node drops a chunk pushed after teardown rather than handing it to a reader that has stopped.
    if (this.destroyed) return false;
    if (chunk === null || chunk === undefined) {
      this._ended = true;
      this._wake();
      this._settleEnd();
      return false;
    }
    const decode = this._encoding && typeof chunk !== "string";
    const value = decode ? Buffer.from(chunk).toString(this._encoding) : chunk;
    // Queueing while a drain is pending is what keeps a body in order: emitting straight away would
    // put this chunk in front of the ones already waiting for the microtask to hand them over.
    if (this._flowing && !this._draining) this.emit("data", value);
    else this._queue.push(value);
    this._wake();
    return true;
  }

  // Node starts a paused stream flowing the moment someone listens for `data`; a consumer that
  // attaches late would otherwise never see chunks pushed before it arrived.
  on(event, listener) {
    super.on(event, listener);
    if (event === "data") this.resume();
    // Node replays `end` to a listener that arrives after the stream finished, which a buffered
    // source always is: its whole body is pushed before the consumer can attach.
    if (event === "end" && this._endEmitted) queueMicrotask(() => listener.call(this));
    return this;
  }

  resume() {
    this._flowing = true;
    // Deferred: a second listener attaching in the same tick must not find the queue already
    // drained by the first, which is how a tee ends up feeding only its first destination.
    if (this._draining) return this;
    this._draining = true;
    queueMicrotask(() => {
      this._draining = false;
      while (this._flowing && this._queue.length) this.emit("data", this._queue.shift());
      this._settleEnd();
    });
    return this;
  }

  pause() {
    this._flowing = false;
    return this;
  }

  pipe(destination, options) {
    super.pipe(destination, options);
    this.resume();
    return destination;
  }

  destroy(error) {
    this.destroyed = true;
    this._failure = error ?? null;
    // A destroyed stream is finished either way: without this an iterator parked on a bare
    // `destroy()` finds no failure and no end, and re-parks forever.
    this._ended = true;
    this._wake();
    this._failAndClose(error);
    return this;
  }

  async *[Symbol.asyncIterator]() {
    // Reads through `data` rather than off the queue: taking chunks straight from `_queue` makes an
    // iterator and a listener race for the same body, and each one sees only the half it won.
    const buffered = [];
    const onData = (chunk) => {
      buffered.push(chunk);
      this._wake();
    };
    this.on("data", onData);
    try {
      while (true) {
        if (buffered.length) {
          yield buffered.shift();
          continue;
        }
        if (this._failure) throw this._failure;
        // `_queue` may still hold chunks whose delivery is only scheduled, and those come first.
        if (this._ended && !this._queue.length) return;
        await new Promise((resolve) => this._waiters.push(resolve));
      }
    } finally {
      this.off("data", onData);
    }
  }

  /// `end` waits for the queue to drain: a paused consumer that reads later must not be told the
  /// stream finished before it has seen the chunks still sitting in front of it.
  _settleEnd() {
    // A destroyed stream is `_ended` so a parked reader stops, but it finished by being torn down:
    // Node emits `close` alone there, never the `end` that says the body arrived whole.
    if (this.destroyed || !this._ended || this.readableEnded || this._queue.length) return;
    this.readableEnded = true;
    queueMicrotask(() => {
      this._endEmitted = true;
      this.emit("end");
      this._emitClose();
    });
  }

  _wake() {
    const waiters = this._waiters;
    this._waiters = [];
    for (const resolve of waiters) resolve();
  }

  // Node yields a string or a Buffer whole rather than iterating it byte by byte.
  static from(source) {
    const readable = new Readable();
    if (typeof source === "string" || source instanceof Uint8Array) {
      readable.push(source);
      readable.push(null);
      return readable;
    }
    (async () => {
      try {
        for await (const chunk of source) readable.push(chunk);
        readable.push(null);
      } catch (error) {
        readable.destroy(error);
      }
    })();
    return readable;
  }
}

export class Writable extends Stream {
  constructor(options = {}) {
    super();
    this.writable = true;
    this.writableEnded = false;
    this.destroyed = false;
    this._closed = false;
    this._written = [];
    if (typeof options.write === "function") this._write = options.write;
    if (typeof options.final === "function") this._final = options.final;
  }

  write(chunk, encoding, callback) {
    if (typeof encoding === "function") {
      callback = encoding;
      encoding = null;
    }
    // Node refuses a write once the stream has ended rather than appending to a body that has
    // already been handed on — a request whose payload grew after it was sent is unexplainable
    // from the call site, so the failure has to be the error Node raises.
    if (this.writableEnded) return this._failWriteAfterEnd(callback);
    this._write(chunk, encoding, callback ?? (() => {}));
    return true;
  }

  end(chunk, encoding, callback) {
    if (typeof chunk === "function") {
      callback = chunk;
      chunk = undefined;
    } else if (typeof encoding === "function") {
      callback = encoding;
      encoding = null;
    }
    // The second `end()` is itself a write-after-end, chunk or not.
    if (this.writableEnded) {
      this._failWriteAfterEnd(callback);
      return this;
    }
    if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);
    this.writableEnded = true;
    this._final(() => {
      callback?.();
      this.emit("finish");
      this._closeAfterFinish();
    });
    return this;
  }

  _write(chunk, _encoding, callback) {
    this._written.push(chunk);
    callback();
  }

  _final(callback) {
    callback();
  }

  destroy(error) {
    this.destroyed = true;
    this._failAndClose(error);
    return this;
  }

  /// A write-only stream is done the moment it finishes; a Duplex overrides this to wait for its
  /// readable half, so `close` stays the single last event Node promises rather than a mid-stream one.
  _closeAfterFinish() {
    this._emitClose();
  }
}

/// Both halves at once, which single inheritance cannot express: it extends `Readable` and delegates
/// the writable side to `Writable`'s own methods rather than copying that prototype across.
export class Duplex extends Readable {
  constructor(options = {}) {
    super(options);
    this.writable = true;
    this.writableEnded = false;
    this._written = [];
    if (typeof options.write === "function") this._write = options.write;
    if (typeof options.final === "function") this._final = options.final;
  }
  write(chunk, encoding, callback) {
    return Writable.prototype.write.call(this, chunk, encoding, callback);
  }
  end(chunk, encoding, callback) {
    return Writable.prototype.end.call(this, chunk, encoding, callback);
  }
  destroy(error) {
    return Readable.prototype.destroy.call(this, error);
  }
  // The readable half emits `close` once it ends, which is what keeps Node's finish → end → close.
  _closeAfterFinish() {}
  _write(chunk, _encoding, callback) {
    this._written.push(chunk);
    callback();
  }
  _final(callback) {
    callback();
  }
}

export class Transform extends Duplex {
  constructor(options = {}) {
    super(options);
    if (typeof options.transform === "function") this._transform = options.transform;
  }

  _transform(chunk, _encoding, callback) {
    callback(null, chunk);
  }

  _write(chunk, encoding, callback) {
    this._transform(chunk, encoding, (error, value) => {
      if (error) this.destroy(error);
      else if (value !== undefined && value !== null) this.push(value);
      callback();
    });
  }

  _final(callback) {
    this.push(null);
    callback();
  }
}

export class PassThrough extends Transform {}

/// Callback form, so `util.promisify(stream.pipeline)` works. Completion comes from the last stage:
/// a source ends its destination when it ends, which is what `Readable.pipe` wires up.
export function pipeline(...stages) {
  const callback = typeof stages[stages.length - 1] === "function" ? stages.pop() : null;
  let settled = false;
  const finish = (error) => {
    if (settled) return;
    settled = true;
    callback?.(error ?? null);
  };
  // Listen before piping: `pipe` resumes the source and drains it synchronously, so a stage that
  // fails during that drain would emit `error` before a listener attached afterwards existed —
  // and the `end` that follows would then report the failed pipeline as a success.
  // A stage torn down by `destroy()` never ends, so its `close` has to settle the pipeline too.
  for (const stage of stages) {
    stage.on?.("error", finish);
    stage.on?.("close", () => {
      const premature = prematureClose(stage);
      if (premature) finish(premature);
    });
  }
  const last = stages.reduce((from, to) => from.pipe(to));
  last.on("finish", () => finish());
  last.on("end", () => finish());
  return last;
}

/// Completes once, and on `close` too: a stream torn down by `destroy()` emits neither `end` nor
/// `finish`, so without that branch an awaited `finished`/`pipeline` parks for the whole session.
export function finished(stream, callback) {
  let settled = false;
  const settle = (error) => {
    if (settled) return;
    settled = true;
    callback(error ?? null);
  };
  // A stream that already finished emits nothing further, so its state has to answer in place of
  // an event that has been and gone — otherwise an awaited `finished` parks for the whole session.
  if (stream.destroyed || stream.readableEnded || stream.writableEnded) {
    queueMicrotask(() => settle(stream._failure ?? prematureClose(stream)));
    return;
  }
  stream.on("error", settle);
  stream.on("end", () => settle());
  stream.on("finish", () => settle());
  stream.on("close", () => settle(prematureClose(stream)));
}

/// Node reports a stream that closed before it ended as `ERR_STREAM_PREMATURE_CLOSE`; a clean close
/// arrives after `end`/`finish` has already settled the callback, so this reaches only a real one.
function prematureClose(stream) {
  if (stream.readableEnded || stream.writableEnded) return null;
  const error = new Error("Premature close");
  error.code = "ERR_STREAM_PREMATURE_CLOSE";
  return error;
}

function promisify(fn, args) {
  return new Promise((resolve, reject) => fn(...args, (error) => (error ? reject(error) : resolve())));
}

const WEB_STREAMS_REASON = "is not available in Tinycast extensions (JavaScriptCore has no web streams).";

const WEB_STREAM_NAMES = [
  "ReadableStream",
  "WritableStream",
  "TransformStream",
  "ByteLengthQueuingStrategy",
  "CountQueuingStrategy",
];

/// JavaScriptCore ships no web streams, and `node-fetch` carries its own polyfill behind a `try` —
/// so throwing on access is what installs it. A module that resolves to nothing leaves it with
/// neither, because the copy it does then quietly succeeds.
export const webStreams = globalThis.ReadableStream
  ? Object.fromEntries(WEB_STREAM_NAMES.map((name) => [name, globalThis[name]]).filter(([, value]) => value))
  : new Proxy(
      {},
      {
        ownKeys: () => WEB_STREAM_NAMES,
        getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }),
        get(_target, member) {
          // Only a web-stream name throws: an interop key must stay absent or a static
          // `import … from "node:stream/web"` dies on the probe, before the polyfill is reached.
          if (typeof member !== "string" || RESERVED_MEMBERS.has(member)) return undefined;
          throw new Error(`stream/web ${WEB_STREAMS_REASON}`);
        },
      },
    );

Object.assign(Stream, {
  Stream,
  Readable,
  Writable,
  Duplex,
  Transform,
  PassThrough,
  pipeline,
  finished,
  promises: {
    pipeline: (...stages) => promisify(pipeline, stages),
    finished: (stream) => promisify(finished, [stream]),
  },
});

export const streamModule = Stream;
