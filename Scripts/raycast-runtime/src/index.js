// Entry point: installs the polyfills and module registry, then exposes `__tinycast` to Swift.

import "./polyfills.js";
import "./url.js";
import { createElement } from "react";
import * as React from "react";
import * as JSXRuntime from "react/jsx-runtime";
import { describeError, hostRaw, log, setUncaughtHandler, settle } from "./host.js";
import { fireTimer } from "./polyfills.js";
import { configureNodeShims } from "./node-shims.js";
import { defineModule, evaluateCommonJS } from "./modules.js";
import { resolveComponent } from "./async-component.js";
import { NavigationRoot, setFieldCommandHandler } from "./api/components.js";
import { Surface } from "./reconciler.js";
import { raycastApi } from "./api/index.js";
import { configureSystem, runToastAction } from "./api/system.js";
import { WebSocket } from "./websocket.js";

const reactModule = {
  ...React,
  createElement: (type, ...rest) => createElement(resolveComponent(type), ...rest),
};
const jsxModule = {
  ...JSXRuntime,
  jsx: (type, props, key) => JSXRuntime.jsx(resolveComponent(type), props, key),
  jsxs: (type, props, key) => JSXRuntime.jsxs(resolveComponent(type), props, key),
};
reactModule.default = reactModule;
jsxModule.default = jsxModule;

defineModule("react", reactModule);
defineModule("react/jsx-runtime", jsxModule);
defineModule("react/jsx-dev-runtime", jsxModule);
defineModule("@raycast/api", raycastApi);
// react-dom only appears in bundles defensively; make the import resolve and the calls explain.
defineModule("react-dom", {
  render: () => {
    throw new Error("react-dom is not available — Tinycast renders extensions natively.");
  },
  createPortal: (children) => children,
  flushSync: (fn) => fn?.(),
  version: React.version,
});
globalThis.WebSocket = WebSocket;

const sessions = new Map();

class Session {
  constructor(id) {
    this.id = id;
    this.surface = null;
    this.navigationDepth = 1;
    this.navigation = {};
  }

  mountView(element) {
    this.surface = new Surface(
      (tree) => hostRaw.render(this.id, JSON.stringify(tree)),
      (error) => this.fail(error),
    );
    this.surface.render(
      createElement(NavigationRoot, {
        initial: element,
        controls: this.navigation,
        onStackChange: (depth) => {
          this.navigationDepth = depth;
          hostRaw.navigationDepthChanged(this.id, String(depth));
        },
      }),
    );
  }

  fail(error) {
    hostRaw.failed(this.id, describeError(error));
  }

  unmount() {
    this.surface?.unmount();
    this.surface = null;
  }
}


setUncaughtHandler((error) => {
  const message = describeError(error);
  log("error", [message]);
  // With exactly one session running, the rejection is surely its own: show it in the palette.
  if (sessions.size === 1) {
    const [session] = sessions.values();
    session.fail(error);
  }
});

setFieldCommandHandler((command, fieldId) => {
  hostRaw.fieldCommand(String(command), String(fieldId ?? ""));
});

globalThis.__tinycast = {
  boot(configJson) {
    const config = JSON.parse(configJson);
    configureNodeShims(config.node ?? {});
    configureSystem(config);
    return "ok";
  },

  // Menu-bar and view commands mount components; no-view commands await their default export.
  start(sessionId, code, filename, dirname, mode, contextJson) {
    const context = JSON.parse(contextJson || "{}");
    configureSystem(context);
    const session = new Session(sessionId);
    sessions.set(sessionId, session);
    // Commands declaring `arguments` read `props.arguments.<name>` unguarded, so the bag always exists.
    const launchProps = {
      launchType: "userInitiated",
      arguments: {},
      ...(context.launchProps ?? {}),
    };
    try {
      const exports = evaluateCommonJS(code, filename, dirname);
      const entry = exports?.default ?? exports;
      if (mode !== "no-view") {
        if (typeof entry !== "function") {
          throw new Error("A view command must default-export a React component.");
        }
        session.mountView(createElement(resolveComponent(entry), launchProps));
      } else {
        if (typeof entry !== "function") {
          throw new Error("A no-view command must default-export a function.");
        }
        Promise.resolve(entry(launchProps)).then(
          () => hostRaw.finished(sessionId),
          (error) => session.fail(error),
        );
      }
    } catch (error) {
      session.fail(error);
    }
    return "ok";
  },

  dispatch(sessionId, handlerId, argsJson, completesSession = false) {
    const session = sessions.get(sessionId);
    if (!session?.surface) return "0";
    try {
      const args = JSON.parse(argsJson || "[]").map(reviveArg);
      const dispatched = session.surface.dispatch(
        handlerId, args, completesSession ? () => hostRaw.finished(sessionId) : undefined,
      );
      if (!dispatched && completesSession) hostRaw.finished(sessionId);
      return dispatched ? "1" : "0";
    } catch (error) {
      session.fail(error);
      return "0";
    }
  },

  popNavigation(sessionId) {
    const session = sessions.get(sessionId);
    if (!session?.surface || session.navigationDepth <= 1) return "0";
    session.navigation.pop?.();
    return "1";
  },

  settle,
  fireTimer,
  runToastAction,

  stop(sessionId) {
    sessions.get(sessionId)?.unmount();
    sessions.delete(sessionId);
    return "ok";
  },
};

/// `{"$date": …}` is how a Form.DatePicker value crosses back from Swift.
function reviveArg(value) {
  if (value && typeof value === "object") {
    if (typeof value.$date === "string") return new Date(value.$date);
    if (Array.isArray(value)) return value.map(reviveArg);
  }
  return value;
}
