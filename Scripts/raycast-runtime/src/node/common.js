// Helpers every Node shim module shares.

import { hostCallSync } from "../host.js";
import { adoptBytes } from "../buffer.js";
import { base64ToBytes } from "../bytes.js";

export const PROMISIFY_CUSTOM = Symbol.for("nodejs.util.promisify.custom");

export function codedError(message, code, ErrorType = Error) {
  const error = new ErrorType(message);
  error.code = code;
  return error;
}

export const notSupported = (what) => () => {
  throw new Error(`${what} is not supported in Tinycast extensions.`);
};

export const bufferOfBase64 = (text) => adoptBytes(base64ToBytes(text));

/// A blocking host call that answers base64, as a Buffer over the decoded bytes.
export const hostBuffer = (api, method, args) => bufferOfBase64(hostCallSync(api, method, args));

// Callback forms: run the same sync host call, hand the result back on a microtask.
export function callbackify(syncFn) {
  return (...args) => {
    const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
    let value;
    let error = null;
    try {
      value = syncFn(...args);
    } catch (thrown) {
      error = thrown;
    }
    if (!callback) return;
    queueMicrotask(() => callback(error, error ? undefined : value));
  };
}
