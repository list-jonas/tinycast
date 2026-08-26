// Keys an interop layer probes on every module it imports, before the extension touches a member.
// esbuild's `__toESM` reads `__esModule` and `await` reads `then`, so a module that throws on one
// of these dies at import — far from the call the extension actually made. Absent, never throwing.

export const RESERVED_MEMBERS = new Set([
  "__esModule",
  "default",
  "then",
  "catch",
  "prototype",
  "constructor",
  "toJSON",
  "inspect",
  "valueOf",
  "toString",
  "length",
  "name",
]);
