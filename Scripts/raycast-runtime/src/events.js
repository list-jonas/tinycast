// Node's `events`. Its own file because `stream` builds on it and `node-shims` imports both — a
// class shared through the module that also consumes it would be read inside its own TDZ.

import { reportUnheard } from "./polyfills.js";

export class EventEmitter {
  constructor() {
    this._events = new Map();
    this._maxListeners = 10;
  }
  _list(event) {
    if (!this._events.has(event)) this._events.set(event, []);
    return this._events.get(event);
  }
  on(event, listener) {
    this._list(event).push(listener);
    return this;
  }
  addListener(event, listener) {
    return this.on(event, listener);
  }
  prependListener(event, listener) {
    this._list(event).unshift(listener);
    return this;
  }
  once(event, listener) {
    const wrapper = (...args) => {
      this.off(event, wrapper);
      listener(...args);
    };
    wrapper.listener = listener;
    return this.on(event, wrapper);
  }
  off(event, listener) {
    const list = this._events.get(event);
    if (!list) return this;
    const index = list.findIndex((entry) => entry === listener || entry.listener === listener);
    if (index >= 0) list.splice(index, 1);
    return this;
  }
  removeListener(event, listener) {
    return this.off(event, listener);
  }
  removeAllListeners(event) {
    if (event === undefined) this._events.clear();
    else this._events.delete(event);
    return this;
  }
  emit(event, ...args) {
    const list = this._events.get(event);
    if (!list?.length) {
      // Node throws an unheard `error`, which ends the process. Logging it instead is what keeps
      // one failed stream from taking a whole extension down, while still surfacing the cause —
      // swallowing it silently is how a dead request looks like a hang with no explanation.
      if (event === "error") reportUnheard(args[0] ?? new Error("Unhandled error event"));
      return false;
    }
    for (const listener of list.slice()) listener.apply(this, args);
    return true;
  }
  listenerCount(event) {
    return this._events.get(event)?.length ?? 0;
  }
  listeners(event) {
    return (this._events.get(event) ?? []).slice();
  }
  eventNames() {
    return Array.from(this._events.keys());
  }
  setMaxListeners(count) {
    this._maxListeners = count;
    return this;
  }
  getMaxListeners() {
    return this._maxListeners;
  }
}
EventEmitter.EventEmitter = EventEmitter;
EventEmitter.defaultMaxListeners = 10;
EventEmitter.once = (emitter, event) =>
  new Promise((resolve) => emitter.once(event, (...args) => resolve(args)));
