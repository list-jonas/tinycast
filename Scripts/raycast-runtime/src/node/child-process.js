// `child_process›: sync forms are one blocking host call, async ones start a child and wait on it.

import { hostCall, hostCallSync } from "../host.js";
import { Buffer } from "../buffer.js";
import { base64ToBytes, bytesToBase64, utf8Decode } from "../bytes.js";
import { EventEmitter } from "../events.js";
import { PassThrough } from "../streams.js";
import { PROMISIFY_CUSTOM, bufferOfBase64, notSupported } from "./common.js";
import { process } from "./process.js";

/// Node stringifies every defined value, so `{ ...process.env, DEBUG: 1 }› must not drop the override.
function childEnv(env) {
  if (env == null) return env;
  return Object.fromEntries(Object.entries(env).filter(([, value]) => value !== undefined).map(([key, value]) => [key, String(value)]));
}

function runSpec(shell, command, args, options = {}, input = options.input ? bytesToBase64(Buffer.from(options.input)) : null) {
  return {
    shell,
    command: String(command),
    args: args.map(String),
    cwd: options.cwd,
    env: childEnv(options.env),
    timeout: options.timeout,
    input,
  };
}

const splitArgs = (args, options) => (Array.isArray(args) ? [args, options] : [[], args]);

function normalizeExecResult(raw, options) {
  const wantsBuffer = options?.encoding === "buffer" || options?.encoding === null;
  const decode = (base64) => (wantsBuffer ? bufferOfBase64(base64) : utf8Decode(base64ToBytes(base64)));
  return { stdout: decode(raw.stdout), stderr: decode(raw.stderr), status: raw.status, signal: raw.signal ?? null };
}

function execError(result, command) {
  const error = new Error(
    `Command failed: ${command}\n${typeof result.stderr === "string" ? result.stderr : ""}`.trim(),
  );
  error.code = result.status;
  error.status = result.status;
  error.stdout = result.stdout;
  error.stderr = result.stderr;
  error.killed = false;
  return error;
}

function runSync(spec, options, label) {
  const result = normalizeExecResult(hostCallSync("proc", "run", [spec]), options);
  if (result.status !== 0) throw execError(result, label);
  return result.stdout;
}

export const childProcess = {
  execSync: (command, options = {}) => runSync(runSpec(true, command, [], options), options, command),
  execFileSync(file, args = [], options = {}) {
    [args, options] = splitArgs(args, options);
    return runSync(runSpec(false, file, args, options), options, file);
  },
  spawnSync(file, args = [], options = {}) {
    [args, options] = splitArgs(args, options);
    const raw = hostCallSync("proc", "run", [runSpec(!!options.shell, file, args, options)]);
    const result = normalizeExecResult(raw, options);
    return { ...result, pid: 0, output: [null, result.stdout, result.stderr], error: undefined };
  },
  exec(command, options, callback) {
    if (typeof options === "function") {
      callback = options;
      options = {};
    }
    return runAsync(runSpec(true, command, [], options), options, callback, command);
  },
  execFile(file, args, options, callback) {
    if (typeof args === "function") {
      callback = args;
      args = [];
      options = {};
    } else if (typeof options === "function") {
      callback = options;
      options = {};
    }
    if (!Array.isArray(args)) args = [];
    return runAsync(runSpec(false, file, args, options), options, callback, file);
  },
  spawn(file, args = [], options = {}) {
    [args, options] = splitArgs(args, options);
    return new ChildProcess(String(file), args.map(String), options);
  },
  fork: notSupported("child_process.fork"),
};

// `util.promisify(exec)› resolves to `{stdout, stderr}›: extensions destructure it, as Node advertises.
const promisifyOutput = (run, arity) => (...args) =>
  new Promise((resolve, reject) => {
    args.length = arity;
    run(...args, (error, stdout, stderr) => (error ? reject(Object.assign(error, { stdout, stderr })) : resolve({ stdout, stderr })));
  });
childProcess.exec[PROMISIFY_CUSTOM] = promisifyOutput(childProcess.exec, 2);
childProcess.execFile[PROMISIFY_CUSTOM] = promisifyOutput(childProcess.execFile, 3);

class ChildProcess extends EventEmitter {
  constructor(file, args, options) {
    super();
    this.pid = 0;
    this.killed = false;
    this.exitCode = null;
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this._input = [];
    this._started = false;

    const self = this;
    this.stdin = new EventEmitter();
    this.stdin.writable = true;
    this.stdin.write = (chunk) => (self._input.push(typeof chunk === "string" ? Buffer.from(chunk, "utf8") : Buffer.from(chunk)), true);
    this.stdin.end = (chunk) => { if (chunk !== undefined) this.stdin.write(chunk); self._start(file, args, options); return this.stdin; };
    this.stdin.destroy = () => {};
    this.stdio = [this.stdin, this.stdout, this.stderr];

    // A microtask still collects stdin written right after `spawn()›, and unlike a timer it drains
    // before control returns to Swift, so a fire-and-forget `spawn(...).unref()› still launches.
    queueMicrotask(() => this._start(file, args, options));
  }

  _start(file, args, options) {
    if (this._started) return;
    this._started = true;
    const input = this._input.length ? bytesToBase64(Buffer.concat(this._input)) : null;
    const { pid, exit } = startChild({
      ...runSpec(!!options.shell, file, args, options, input),
      // `detached› only makes a process group; only an unread child may answer before it exits.
      detached: !!options.detached && (Array.isArray(options.stdio) ? options.stdio[1] : options.stdio) === "ignore",
    }, (pid) => Promise.all([pipeChild(pid, 1, this.stdout), pipeChild(pid, 2, this.stderr)]));
    this.pid = pid;
    if (pid) queueMicrotask(() => this.emit("spawn"));
    exit.then(
      (raw) => {
        this.exitCode = raw.status;
        this.stdin.emit("finish");
        this.stdout.end(bufferOfBase64(raw.stdout));
        this.stderr.end(bufferOfBase64(raw.stderr));
        // One host reply carries both, but a reader still expects the output before the exit code.
        queueMicrotask(() => {
          this.emit("exit", raw.status, raw.signal ?? null);
          this.emit("close", raw.status, raw.signal ?? null);
        });
      },
      (error) => {
        // execa awaits stdout, where Node guarantees an empty string even on failure.
        this.exitCode = 1;
        this.stdin.emit("finish");
        this.stdout.end();
        this.stderr.end(Buffer.from(String(error?.message ?? error), "utf8"));
        this.emit("error", error);
        queueMicrotask(() => this.emit("close", 1, null));
      },
    );
  }

  kill(signal) {
    return this.exitCode === null && signalChild(this, signal);
  }

  // Nothing here keeps the runtime alive, so these only chain: `spawn(...).unref()› is a common idiom.
  unref() {
    return this;
  }
  ref() {
    return this;
  }
}

/// Node guarantees `stdout›/`stderr› on a failed exec's error and extensions match on `error.stderr›.
function decorateProcessError(error, label) {
  const decorated = error instanceof Error ? error : new Error(String(error));
  if (decorated.stdout === undefined) decorated.stdout = "";
  if (decorated.stderr === undefined) decorated.stderr = decorated.message;
  if (decorated.status === undefined) decorated.status = 1;
  if (decorated.code === undefined) decorated.code = 1;
  decorated.cmd = decorated.cmd ?? label;
  return decorated;
}

/// Launched synchronously because extensions store `child.pid› right away to `process.kill› it later.
function startChild(spec, drain) {
  try {
    const pid = hostCallSync("proc", "start", [spec]);
    const exit = spec.detached
      ? Promise.resolve({ stdout: "", stderr: "", status: 0 })
      : Promise.resolve(drain?.(pid)).then(() => hostCall("proc", "wait", [pid]));
    return { pid, exit };
  } catch (error) {
    return { pid: undefined, exit: Promise.reject(error) };
  }
}

async function pipeChild(pid, fd, stream) {
  let held = Buffer.alloc(0);
  for (let chunk; (chunk = await hostCall("proc", "read", [pid, fd])); ) {
    const bytes = Buffer.concat([held, base64ToBytes(chunk)]);
    const cut = utf8Boundary(bytes);
    held = bytes.subarray(cut);
    if (cut) stream.write(bytes.subarray(0, cut));
  }
  if (held.length) stream.write(held);
}

/// Holds back a trailing partial UTF-8 character so a chunk never splits one.
function utf8Boundary(bytes) {
  for (let i = bytes.length - 1; i >= Math.max(0, bytes.length - 3); i--) {
    if ((bytes[i] & 0xc0) === 0x80) continue;
    const need = bytes[i] >= 0xf0 ? 4 : bytes[i] >= 0xe0 ? 3 : bytes[i] >= 0xc0 ? 2 : 1;
    return bytes.length - i < need ? i : bytes.length;
  }
  return bytes.length;
}

/// Node's `ChildProcess.kill› reports an undeliverable signal by returning false, never by throwing.
function signalChild(child, signal) {
  if (!child.pid) return false;
  try {
    process.kill(child.pid, signal);
  } catch {
    return false;
  }
  child.killed = true;
  return true;
}

function runAsync(spec, options, callback, label) {
  const { pid, exit } = startChild(spec);
  let exited = false;
  const promise = exit
    .finally(() => {
      exited = true;
    })
    .then((raw) => normalizeExecResult(raw, options))
    .catch((error) => {
      throw decorateProcessError(error, label);
    });
  if (callback) {
    promise.then(
      (result) => callback(result.status === 0 ? null : execError(result, label), result.stdout, result.stderr),
      (error) => callback(error, error.stdout ?? "", error.stderr ?? ""),
    );
  }
  // Node returns a ChildProcess; extensions mostly ignore it or await the promisified form.
  const handle = { pid, killed: false, kill: (signal) => !exited && signalChild(handle, signal), on: () => handle, stdout: null, stderr: null };
  handle.then = promise.then.bind(promise);
  handle.catch = promise.catch.bind(promise);
  handle[PROMISIFY_CUSTOM] = () => promise;
  return handle;
}
