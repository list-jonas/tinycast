// The non-visual half of @raycast/api; every call is an async host call Swift answers on the main actor.

import { hostCall } from "../host.js";
import { nestedEnums } from "./enums.generated.js";

const ToastStyle = nestedEnums.Toast.Style;

let boot = { environment: {}, preferences: {}, launchProps: {} };

export function configureSystem(info) {
  boot = { ...boot, ...info };
}

export function unsupported(what) {
  return Promise.reject(
    new Error(`${what} is not supported in Tinycast extensions yet. See docs/extensions.md.`),
  );
}

// ─── Clipboard ──────────────────────────────────────────────────────

export const Clipboard = {
  copy: (content, options) => hostCall("clipboard", "copy", [normalizeClipboardContent(content), options ?? {}]),
  paste: (content) => hostCall("clipboard", "paste", [normalizeClipboardContent(content)]),
  clear: () => hostCall("clipboard", "clear", []),
  read: (options) => hostCall("clipboard", "read", [options ?? {}]),
  readText: (options) => hostCall("clipboard", "readText", [options ?? {}]),
};

function normalizeClipboardContent(content) {
  if (content === null || content === undefined) return { text: "" };
  if (typeof content === "string") return { text: content };
  if (typeof content === "number") return { text: String(content) };
  return content;
}

// ─── LocalStorage ───────────────────────────────────────────────────

export const LocalStorage = {
  async getItem(key) {
    const value = await hostCall("storage", "get", [String(key)]);
    return value === null ? undefined : value;
  },
  setItem: (key, value) => hostCall("storage", "set", [String(key), value]),
  removeItem: (key) => hostCall("storage", "remove", [String(key)]),
  clear: () => hostCall("storage", "clear", []),
  allItems: () => hostCall("storage", "all", []),
};

// ─── Cache ──────────────────────────────────────────────────────────
// Raycast's Cache is synchronous: Swift hands each namespace over at boot and writes are write-behind.

export class Cache {
  constructor(options = {}) {
    this.namespace = options.namespace ?? "default";
    this.capacity = options.capacity ?? 10 * 1024 * 1024;
    this._entries = new Map(Object.entries(cacheSnapshot(this.namespace)));
    this._subscribers = new Set();
    // `useCachedState` hands `cache.subscribe` to `useSyncExternalStore` unbound.
    for (const method of ["has", "get", "set", "remove", "clear", "subscribe"]) {
      this[method] = Cache.prototype[method].bind(this);
    }
  }

  get isEmpty() {
    return this._entries.size === 0;
  }

  has(key) {
    return this._entries.has(String(key));
  }

  get(key) {
    return this._entries.get(String(key));
  }

  set(key, data) {
    this._entries.set(String(key), String(data));
    this._persist(String(key), String(data));
    this._notify(String(key), String(data));
  }

  remove(key) {
    const existed = this._entries.delete(String(key));
    if (existed) {
      this._persist(String(key), null);
      this._notify(String(key), undefined);
    }
    return existed;
  }

  clear(options = {}) {
    this._entries.clear();
    hostCall("cache", "clear", [this.namespace]).catch(() => {});
    if (options.notifySubscribers !== false) this._notify(undefined, undefined);
  }

  subscribe(subscriber) {
    this._subscribers.add(subscriber);
    return () => void this._subscribers.delete(subscriber);
  }

  _persist(key, value) {
    hostCall("cache", "set", [this.namespace, key, value]).catch(() => {});
  }

  _notify(key, data) {
    for (const subscriber of this._subscribers) {
      try {
        subscriber(key, data);
      } catch {
        // A throwing subscriber must not break the write that triggered it.
      }
    }
  }
}

function cacheSnapshot(namespace) {
  return boot.caches?.[namespace] ?? {};
}

// ─── Preferences & environment ──────────────────────────────────────

export function getPreferenceValues() {
  return { ...boot.preferences };
}

export const environment = new Proxy(
  {},
  {
    get(_target, key) {
      if (key === "canAccess") return () => false;
      return boot.environment?.[key];
    },
    has: (_target, key) => key in (boot.environment ?? {}),
    ownKeys: () => Object.keys(boot.environment ?? {}),
    getOwnPropertyDescriptor: () => ({ enumerable: true, configurable: true }),
  },
);

export const openExtensionPreferences = () => hostCall("window", "openPreferences", ["extension"]);
export const openCommandPreferences = () => hostCall("window", "openPreferences", ["command"]);

// ─── Window / navigation control ────────────────────────────────────

export const closeMainWindow = (options = {}) => hostCall("window", "close", [options]);
export const popToRoot = (options = {}) => hostCall("window", "popToRoot", [options]);
export const clearSearchBar = (options = {}) => hostCall("window", "clearSearchBar", [options]);

// ─── Applications & files ───────────────────────────────────────────

export function open(target, application) {
  const app = typeof application === "string" ? application : application?.bundleId ?? application?.path;
  return hostCall("system", "open", [String(target), app ?? null]);
}

/// Raycast shows an app picker for Action.OpenWith; Swift resolves the candidates and presents them.
export const openWith = (path) => hostCall("system", "openWith", [String(path)]);
export const trash = (paths) => hostCall("system", "trash", [(Array.isArray(paths) ? paths : [paths]).map(String)]);
export const showInFinder = (path) => hostCall("system", "showInFinder", [String(path)]);
export const getApplications = (path) => hostCall("system", "applications", [path ? String(path) : null]);
export const getDefaultApplication = (path) => hostCall("system", "defaultApplication", [String(path)]);
export const getFrontmostApplication = () => hostCall("system", "frontmostApplication", []);
export const getSelectedText = () => hostCall("system", "selectedText", []);
export const getSelectedFinderItems = () => hostCall("system", "selectedFinderItems", []);
export const launchCommand = (options) => hostCall("system", "launchCommand", [options]);
export const updateCommandMetadata = (metadata) => hostCall("system", "updateCommandMetadata", [metadata]);
export const getFrontmostBrowserTab = () => unsupported("getFrontmostBrowserTab");

export function captureException(error) {
  console.error(error instanceof Error ? error.stack || error.message : String(error));
}

// ─── Feedback ───────────────────────────────────────────────────────

export class Toast {
  constructor(options = {}) {
    this._id = null;
    this._options = {
      style: options.style ?? ToastStyle.Success,
      title: options.title ?? "",
      message: options.message,
      primaryAction: options.primaryAction,
      secondaryAction: options.secondaryAction,
    };
  }

  async show() {
    this._id = await hostCall("feedback", "showToast", [this._serialize()]);
    return this;
  }

  async hide() {
    if (this._id === null) return;
    await hostCall("feedback", "hideToast", [this._id]);
    this._id = null;
  }

  _sync() {
    if (this._id === null) return;
    hostCall("feedback", "updateToast", [this._id, this._serialize()]).catch(() => {});
  }

  /// Callbacks can't cross the bridge: Swift gets titles plus a token it echoes to `runToastAction`.
  _serialize() {
    const encode = (action, slotName) => {
      if (!action) return null;
      const token = `${this._token()}:${slotName}`;
      toastActions.set(token, action.onAction);
      return { title: action.title, shortcut: action.shortcut, token };
    };
    return {
      style: this._options.style,
      title: this._options.title,
      message: this._options.message,
      primaryAction: encode(this._options.primaryAction, "primary"),
      secondaryAction: encode(this._options.secondaryAction, "secondary"),
    };
  }

  _token() {
    if (!this._tokenBase) this._tokenBase = `toast-${nextToastToken++}`;
    return this._tokenBase;
  }
}

// Every option is live: assigning one on a shown toast updates it in place.
for (const name of ["style", "title", "message", "primaryAction", "secondaryAction"]) {
  Object.defineProperty(Toast.prototype, name, {
    get() {
      return this._options[name];
    },
    set(value) {
      this._options[name] = value;
      this._sync();
    },
    configurable: true,
  });
}

Toast.Style = ToastStyle;

let nextToastToken = 1;
const toastActions = new Map();

export function runToastAction(token) {
  const handler = toastActions.get(token);
  if (!handler) return;
  // Raycast hands the live Toast to the callback; the shim passes the token holder's own toast.
  handler({ hide: () => {} });
}

export async function showToast(optionsOrStyle, title, message) {
  const options =
    typeof optionsOrStyle === "object" && optionsOrStyle !== null
      ? optionsOrStyle
      : { style: optionsOrStyle, title, message };
  const toast = new Toast(options);
  await toast.show();
  return toast;
}

export const showHUD = (title, options = {}) => hostCall("feedback", "showHUD", [String(title), options]);

export function confirmAlert(options = {}) {
  return hostCall("feedback", "confirmAlert", [
    {
      title: options.title,
      message: options.message,
      icon: options.icon,
      primaryAction: options.primaryAction ? { title: options.primaryAction.title, style: options.primaryAction.style } : null,
      dismissAction: options.dismissAction ? { title: options.dismissAction.title, style: options.dismissAction.style } : null,
      rememberUserChoice: !!options.rememberUserChoice,
    },
  ]).then((confirmed) => {
    if (confirmed) options.primaryAction?.onAction?.();
    else options.dismissAction?.onAction?.();
    return confirmed;
  });
}

// ─── Deprecated aliases still used by older extensions ──────────────

export const copyTextToClipboard = Clipboard.copy;
export const pasteText = Clipboard.paste;
export const clearClipboard = Clipboard.clear;
export const getLocalStorageItem = LocalStorage.getItem;
export const setLocalStorageItem = LocalStorage.setItem;
export const removeLocalStorageItem = LocalStorage.removeItem;
export const allLocalStorageItems = LocalStorage.allItems;
export const clearLocalStorage = LocalStorage.clear;
export const randomId = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e9).toString(36)}`;
