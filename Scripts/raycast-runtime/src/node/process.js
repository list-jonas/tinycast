// `path`, `process` and `os`: the shims that read the boot environment Swift hands over.

import { hostCallSync } from "../host.js";
import { reportUncaught } from "../polyfills.js";
import { codedError, notSupported } from "./common.js";

function normalizeSegments(parts, allowAboveRoot) {
  const out = [];
  for (const part of parts) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (out.length && out[out.length - 1] !== "..") out.pop();
      else if (allowAboveRoot) out.push("..");
    } else {
      out.push(part);
    }
  }
  return out;
}

export const path = {
  sep: "/",
  delimiter: ":",
  normalize(input) {
    const text = String(input);
    if (!text) return ".";
    const absolute = text.startsWith("/");
    let joined = normalizeSegments(text.split("/"), !absolute).join("/");
    if (!joined && !absolute) joined = ".";
    if (joined && text.endsWith("/")) joined += "/";
    return absolute ? "/" + joined : joined;
  },
  join(...parts) {
    const joined = parts.filter((part) => part !== undefined && part !== null && part !== "").join("/");
    return joined ? path.normalize(joined) : ".";
  },
  resolve(...parts) {
    let resolved = "";
    for (let i = parts.length - 1; i >= 0; i--) {
      const part = parts[i];
      if (!part) continue;
      resolved = resolved ? `${part}/${resolved}` : String(part);
      if (String(part).startsWith("/")) break;
    }
    if (!resolved.startsWith("/")) resolved = `${process.cwd()}/${resolved}`;
    const normalized = "/" + normalizeSegments(resolved.split("/"), false).join("/");
    return normalized === "/" ? "/" : normalized.replace(/\/$/, "");
  },
  isAbsolute: (input) => String(input).startsWith("/"),
  dirname(input) {
    const text = String(input).replace(/\/+$/, "");
    const index = text.lastIndexOf("/");
    if (index < 0) return ".";
    if (index === 0) return "/";
    return text.slice(0, index);
  },
  basename(input, ext) {
    const text = String(input).replace(/\/+$/, "");
    let base = text.slice(text.lastIndexOf("/") + 1);
    if (ext && base.endsWith(ext) && base !== ext) base = base.slice(0, -ext.length);
    return base;
  },
  extname(input) {
    const base = path.basename(input);
    const dot = base.lastIndexOf(".");
    return dot <= 0 ? "" : base.slice(dot);
  },
  relative(from, to) {
    const fromParts = path.resolve(from).split("/").filter(Boolean);
    const toParts = path.resolve(to).split("/").filter(Boolean);
    let shared = 0;
    while (shared < fromParts.length && shared < toParts.length && fromParts[shared] === toParts[shared]) {
      shared++;
    }
    return [...Array(fromParts.length - shared).fill(".."), ...toParts.slice(shared)].join("/");
  },
  parse(input) {
    const dir = path.dirname(input);
    const base = path.basename(input);
    const ext = path.extname(base);
    return { root: String(input).startsWith("/") ? "/" : "", dir, base, ext, name: base.slice(0, base.length - ext.length) };
  },
  format(parsed) {
    const dir = parsed.dir || parsed.root || "";
    const base = parsed.base || `${parsed.name || ""}${parsed.ext || ""}`;
    return dir ? (dir === "/" ? "/" + base : `${dir}/${base}`) : base;
  },
  toNamespacedPath: (input) => input,
};
path.posix = path;
path.win32 = path;

let bootEnvironment = { platform: "darwin", arch: "arm64", env: {}, cwd: "/", homedir: "/", tmpdir: "/tmp", execPath: "" };

export function configureNodeShims(info) {
  bootEnvironment = { ...bootEnvironment, ...info };
  process.env = bootEnvironment.env;
  process.arch = bootEnvironment.arch;
  process.execPath = bootEnvironment.execPath;
}

const processListeners = new Map();

const SIGNALS = {
  SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGILL: 4, SIGTRAP: 5, SIGABRT: 6, SIGIOT: 6, SIGFPE: 8, SIGKILL: 9,
  SIGBUS: 10, SIGSEGV: 11, SIGSYS: 12, SIGPIPE: 13, SIGALRM: 14, SIGTERM: 15, SIGURG: 16, SIGSTOP: 17,
  SIGTSTP: 18, SIGCONT: 19, SIGCHLD: 20, SIGTTIN: 21, SIGTTOU: 22, SIGIO: 23, SIGXCPU: 24, SIGXFSZ: 25,
  SIGVTALRM: 26, SIGPROF: 27, SIGWINCH: 28, SIGINFO: 29, SIGUSR1: 30, SIGUSR2: 31,
};

function signalNumber(signal) {
  if (typeof signal === "number") return signal;
  if (Object.hasOwn(SIGNALS, signal)) return SIGNALS[signal];
  throw codedError(`Unknown signal: ${signal}`, "ERR_UNKNOWN_SIGNAL", TypeError);
}

const stdio = (write) => ({ write: (text) => write(String(text).replace(/\n$/, "")), isTTY: false, columns: 80 });

export const process = {
  // Axios gates its Node http adapter on this tag; untagged, axios takes the fetch path.
  [Symbol.toStringTag]: "process",
  platform: "darwin",
  arch: "arm64",
  version: "v22.0.0",
  versions: { node: "22.0.0", v8: "12.0.0", tinycast: "1" },
  argv: ["node", "extension"],
  argv0: "node",
  execArgv: [],
  execPath: "",
  pid: 1,
  ppid: 0,
  env: {},
  title: "tinycast-extension",
  stdout: stdio((text) => console.log(text)),
  stderr: stdio((text) => console.error(text)),
  stdin: { on: () => {}, resume: () => {}, pause: () => {}, isTTY: false },
  cwd: () => bootEnvironment.cwd,
  chdir: notSupported("process.chdir"),
  exit: notSupported("process.exit"),
  kill(pid, signal = "SIGTERM") {
    hostCallSync("proc", "kill", [Number(pid), signalNumber(signal)]);
    return true;
  },
  nextTick: (callback, ...args) => {
    queueMicrotask(() => {
      try {
        callback(...args);
      } catch (error) {
        reportUncaught(error);
      }
    });
  },
  hrtime: Object.assign(
    (previous) => {
      const now = Date.now() * 1e6;
      const seconds = Math.floor(now / 1e9);
      const nanos = now % 1e9;
      if (!previous) return [seconds, nanos];
      return [seconds - previous[0], nanos - previous[1]];
    },
    { bigint: () => BigInt(Math.round(Date.now() * 1e6)) },
  ),
  uptime: () => Date.now() / 1000,
  memoryUsage: () => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0 }),
  emitWarning: (warning) => console.warn(String(warning)),
  on(event, listener) {
    if (!processListeners.has(event)) processListeners.set(event, new Set());
    processListeners.get(event).add(listener);
    return process;
  },
  off(event, listener) {
    processListeners.get(event)?.delete(listener);
    return process;
  },
  removeAllListeners(event) {
    if (event) processListeners.delete(event);
    else processListeners.clear();
    return process;
  },
  listeners: (event) => Array.from(processListeners.get(event) ?? []),
  emit(event, ...args) {
    const listeners = processListeners.get(event);
    if (!listeners?.size) return false;
    for (const listener of listeners) {
      try {
        listener(...args);
      } catch (error) {
        reportUncaught(error);
      }
    }
    return true;
  },
};
process.once = process.addListener = process.on;
process.removeListener = process.off;

export const os = {
  EOL: "\n",
  platform: () => "darwin",
  type: () => "Darwin",
  arch: () => bootEnvironment.arch,
  release: () => bootEnvironment.release || "",
  homedir: () => bootEnvironment.homedir,
  tmpdir: () => bootEnvironment.tmpdir,
  hostname: () => bootEnvironment.hostname || "localhost",
  userInfo: () => ({
    username: bootEnvironment.username || "",
    homedir: bootEnvironment.homedir,
    shell: bootEnvironment.shell || "/bin/zsh",
    uid: 501,
    gid: 20,
  }),
  cpus: () => hostCallSync("os", "cpus", []),
  totalmem: () => bootEnvironment.totalmem || 0,
  freemem: () => hostCallSync("os", "freemem", []),
  uptime: () => hostCallSync("os", "uptime", []),
  loadavg: () => hostCallSync("os", "loadavg", []),
  networkInterfaces: () => ({}),
  endianness: () => "LE",
  devNull: "/dev/null",
  constants: { signals: SIGNALS, errno: {} },
};

