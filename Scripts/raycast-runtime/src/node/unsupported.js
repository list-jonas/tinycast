// Modules that resolve but refuse to run: bundles reference the whole long tail of Node builtins
// from dependencies that only touch them on paths an extension never reaches.

/// Node's function exports per module: a lazy member survives `__toESM› only as an own key.
const UNSUPPORTED_EXPORTS = {
  net: ["BlockList", "SocketAddress", "connect", "createConnection", "createServer", "isIP", "isIPv4", "isIPv6", "Server", "Socket", "Stream"],
  tls: ["getCiphers", "checkServerIdentity", "convertALPNProtocols", "createSecureContext", "SecureContext", "TLSSocket", "Server", "createServer", "connect"],
  dns: ["lookup", "lookupService", "Resolver", "getServers", "setServers", "getDefaultResultOrder", "setDefaultResultOrder", "resolve", "resolve4", "resolve6", "resolveAny", "resolveCaa", "resolveCname", "resolveMx", "resolveNaptr", "resolveNs", "resolvePtr", "resolveSoa", "resolveSrv", "resolveTlsa", "resolveTxt", "reverse"],
  vm: ["Script", "createContext", "createScript", "runInContext", "runInNewContext", "runInThisContext", "isContext", "compileFunction", "measureMemory"],
  readline: ["Interface", "clearLine", "clearScreenDown", "createInterface", "cursorTo", "emitKeypressEvents", "moveCursor"],
  worker_threads: ["MessagePort", "MessageChannel", "markAsUncloneable", "markAsUntransferable", "isMarkedAsUntransferable", "moveMessagePortToContext", "receiveMessageOnPort", "postMessageToThread", "Worker", "BroadcastChannel", "setEnvironmentData", "getEnvironmentData"],
  http2: ["connect", "createServer", "createSecureServer", "getDefaultSettings", "getPackedSettings", "getUnpackedSettings", "performServerHandshake", "Http2ServerRequest", "Http2ServerResponse"],
  domain: ["Domain", "createDomain", "create"],
  diagnostics_channel: ["channel", "hasSubscribers", "subscribe", "unsubscribe", "tracingChannel", "Channel"],
  "stream/consumers": ["arrayBuffer", "blob", "buffer", "text", "json"],
};

// A truthy `__esModule› makes `__toESM› skip its default-wrapping; a truthy `then› makes a thenable.
const RESERVED_MEMBERS = new Set(["__esModule", "default", "then", "catch", "prototype", "constructor", "toJSON", "inspect", "valueOf", "toString", "length", "name"]);

/// Every unknown member is a class that throws when constructed or called: bundles routinely do
/// `class Foo extends stream.Readable› at load time and only reach the runtime path conditionally.
export function unsupportedModule(name, extras = {}) {
  const cache = new Map();
  const lazy = new Set((UNSUPPORTED_EXPORTS[name] ?? []).filter((each) => !(each in extras)));
  const manufacture = (member) => {
    if (!cache.has(member)) cache.set(member, makeUnsupported(`${name}.${member}`));
    return cache.get(member);
  };
  return new Proxy(extras, {
    get(target, member) {
      if (member in target) return target[member];
      if (typeof member !== "string" || RESERVED_MEMBERS.has(member)) return undefined;
      return manufacture(member);
    },
    // esbuild's `__toESM› snapshots own keys and never reads through `get›.
    ownKeys: (target) => [...new Set([...Reflect.ownKeys(target), ...lazy])],
    getOwnPropertyDescriptor(target, member) {
      const own = Reflect.getOwnPropertyDescriptor(target, member);
      if (own || !lazy.has(member)) return own;
      return { value: manufacture(member), writable: true, enumerable: true, configurable: true };
    },
  });
}

function makeUnsupported(label) {
  const reason = `${label} is not supported in Tinycast extensions (no Node runtime). See docs/extensions.md.`;
  const Unsupported = class {
    constructor() {
      throw new Error(reason);
    }
  };
  // Callable as a plain function too — `stream.pipeline(...)›, `https.request(...)›.
  return new Proxy(Unsupported, {
    apply() {
      throw new Error(reason);
    },
  });
}

