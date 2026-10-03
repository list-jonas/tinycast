// Event, EventTarget and MessageChannel — WebCore APIs, like TextEncoder: undici extends Event and
// EventTarget at module scope.

import { reportUncaught } from "./host.js";

const g = globalThis;

class TinycastEvent {
  constructor(type, init = {}) {
    if (arguments.length === 0) throw new TypeError("Event constructor requires a type argument.");
    this.type = String(type);
    this.bubbles = !!init.bubbles;
    this.cancelable = !!init.cancelable;
    this.composed = !!init.composed;
    this.defaultPrevented = false;
    this.isTrusted = false;
    this.target = null;
    this.currentTarget = null;
    this.eventPhase = 0;
    this.timeStamp = Date.now();
    this._stopped = false;
  }
  preventDefault() {
    if (this.cancelable) this.defaultPrevented = true;
  }
  stopPropagation() {}
  stopImmediatePropagation() {
    this._stopped = true;
  }
}

// A WeakMap rather than a field: subclasses and `Object.create` instances never run our constructor.
const eventListeners = new WeakMap();

function listenersOf(target, type) {
  let byType = eventListeners.get(target);
  if (!byType) eventListeners.set(target, (byType = new Map()));
  let list = byType.get(type);
  if (!list) byType.set(type, (list = []));
  return list;
}

class TinycastEventTarget {
  addEventListener(type, callback, options) {
    if (callback == null) return;
    const { capture = false, once = false, signal } = typeof options === "boolean" ? { capture: options } : (options ?? {});
    if (signal?.aborted) return;
    const list = listenersOf(this, String(type));
    if (list.some((each) => each.callback === callback && each.capture === !!capture)) return;
    list.push({ callback, capture: !!capture, once: !!once, removed: false });
    signal?.addEventListener("abort", () => this.removeEventListener(type, callback, { capture }));
  }
  removeEventListener(type, callback, options) {
    const capture = !!(typeof options === "boolean" ? options : options?.capture);
    const list = eventListeners.get(this)?.get(String(type));
    const index = list?.findIndex((each) => each.callback === callback && each.capture === capture) ?? -1;
    if (index === -1) return;
    list[index].removed = true;
    list.splice(index, 1);
  }
  dispatchEvent(event) {
    if (!(event instanceof TinycastEvent)) throw new TypeError("dispatchEvent requires an Event.");
    event.target = this;
    event.currentTarget = this;
    event.eventPhase = 2;
    for (const listener of [...(eventListeners.get(this)?.get(event.type) ?? [])]) {
      if (listener.removed) continue;
      if (listener.once) this.removeEventListener(event.type, listener.callback, { capture: listener.capture });
      try {
        if (typeof listener.callback === "function") listener.callback.call(this, event);
        else listener.callback.handleEvent?.(event);
      } catch (error) {
        reportUncaught(error);
      }
      if (event._stopped) break;
    }
    event.currentTarget = null;
    event.eventPhase = 0;
    return !event.defaultPrevented;
  }
}

class TinycastMessageEvent extends TinycastEvent {
  constructor(data) {
    super("message");
    this.data = data;
    this.ports = [];
  }
}

// Node's port starts on its first "message" listener, not only on `start()` as a browser's does.
class TinycastMessagePort extends TinycastEventTarget {
  _peer = null;
  _queue = [];
  _started = false;
  _closed = false;
  _onmessage = null;
  postMessage(message) {
    if (!this._peer) return;
    this._peer._receive(g.structuredClone(message));
  }
  start() {
    if (this._started || this._closed) return;
    this._started = true;
    for (const data of this._queue.splice(0)) this._schedule(data);
  }
  close() {
    this._closed = true;
    if (this._peer) this._peer._peer = null;
    this._peer = null;
    this._queue = [];
  }
  addEventListener(type, callback, options) {
    super.addEventListener(type, callback, options);
    if (type === "message") this.start();
  }
  get onmessage() {
    return this._onmessage;
  }
  set onmessage(handler) {
    if (this._onmessage) this.removeEventListener("message", this._onmessage);
    this._onmessage = typeof handler === "function" ? handler : null;
    if (this._onmessage) this.addEventListener("message", this._onmessage);
  }
  _receive(data) {
    if (this._started) this._schedule(data);
    else this._queue.push(data);
  }
  _schedule(data) {
    setTimeout(() => {
      if (!this._closed) this.dispatchEvent(new TinycastMessageEvent(data));
    }, 0);
  }
}

class TinycastMessageChannel {
  constructor() {
    this.port1 = new TinycastMessagePort();
    this.port2 = new TinycastMessagePort();
    this.port1._peer = this.port2;
    this.port2._peer = this.port1;
  }
}

if (!g.EventTarget) {
  g.Event = TinycastEvent;
  g.EventTarget = TinycastEventTarget;
}
if (!g.MessageChannel) {
  g.MessagePort = TinycastMessagePort;
  g.MessageChannel = TinycastMessageChannel;
}
