// The single seam between the JS runtime and Swift, which installs `__tinycastHost` before evaluation.

const raw = globalThis.__tinycastHost;
if (!raw) throw new Error("__tinycastHost missing — the runtime was evaluated outside Tinycast.");

export const hostRaw = raw;

let nextCallId = 1;
const pending = new Map();

/// Swift answers through `__tinycast.settle`, so the JS thread never blocks on the main actor.
export function hostCall(api, method, args) {
  return new Promise((resolve, reject) => {
    const callId = nextCallId++;
    pending.set(callId, { resolve, reject });
    try {
      raw.invoke(String(callId), api, method, JSON.stringify(args === undefined ? [] : args));
    } catch (error) {
      pending.delete(callId);
      reject(error);
    }
  });
}

/// Node shims only: Swift services these on the JS thread, so blocking can't deadlock against the UI.
export function hostCallSync(api, method, args) {
  const json = hostRaw.invokeSync(api, method, JSON.stringify(args === undefined ? [] : args));
  const result = json ? JSON.parse(json) : { ok: true };
  if (result.ok) return result.value;
  const error = new Error(String(result.error || `${api}.${method} failed`));
  if (result.code) error.code = result.code;
  if (result.errno !== undefined) error.errno = result.errno;
  if (result.path) error.path = result.path;
  throw error;
}

export function settle(callId, ok, payload) {
  const entry = pending.get(Number(callId));
  if (!entry) return;
  pending.delete(Number(callId));
  if (ok) {
    entry.resolve(payload === undefined || payload === "" ? undefined : JSON.parse(payload));
  } else {
    entry.reject(new Error(String(payload || "Host call failed")));
  }
}

export function log(level, parts) {
  let text;
  try {
    text = parts.map(formatLogArg).join(" ");
  } catch {
    text = "[unserializable log argument]";
  }
  raw.log(level, text);
}

function formatLogArg(value) {
  if (typeof value === "string") return value;
  if (value instanceof Error) return describeError(value);
  if (value === undefined) return "undefined";
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

/// JavaScriptCore's `Error.stack` is frames only, so the headline has to be prepended.
export function describeError(error) {
  if (!(error instanceof Error)) return String(error);
  const headline = `${error.name || "Error"}: ${error.message}`;
  const stack = String(error.stack || "");
  if (!stack) return headline;
  return stack.startsWith(headline) ? stack : `${headline}\n${stack}`;
}

let uncaughtSink = (error) => log("error", ["Uncaught:", error]);

export function setUncaughtHandler(handler) {
  uncaughtSink = handler;
}

export function reportUncaught(error) {
  try {
    uncaughtSink(error);
  } catch {
    log("error", ["Uncaught (and the handler threw):", error]);
  }
}
