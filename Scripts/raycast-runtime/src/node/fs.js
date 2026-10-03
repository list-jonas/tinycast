// `fs› and `fs/promises›. Every call is a blocking host call: Swift services them on the JS thread.

import { hostCallSync } from "../host.js";
import { Buffer } from "../buffer.js";
import { base64ToBytes, bytesToBase64, utf8Decode, utf8Encode } from "../bytes.js";
import { Readable, Writable } from "../streams.js";
import { fileURLToPath, URL } from "../url.js";
import { callbackify, codedError, hostBuffer, notSupported } from "./common.js";

const encodingOf = (options) => (typeof options === "string" ? options : options?.encoding);

function encodeFileData(data, options) {
  if (typeof data === "string") return bytesToBase64(Buffer.from(data, encodingOf(options) || "utf8"));
  if (data instanceof Uint8Array) return bytesToBase64(data);
  if (data instanceof ArrayBuffer) return bytesToBase64(new Uint8Array(data));
  return bytesToBase64(utf8Encode(String(data)));
}

class FileKind {
  isFile() {
    return !!this._isFile;
  }
  isDirectory() {
    return !!this._isDirectory;
  }
  isSymbolicLink() {
    return !!this._isSymbolicLink;
  }
}

class Stats extends FileKind {
  constructor(raw) {
    super();
    Object.assign(this, raw);
    for (const name of ["atime", "mtime", "ctime", "birthtime"]) this[name] = new Date(raw[`${name}Ms`] || 0);
  }
  isBlockDevice() {
    return false;
  }
  isCharacterDevice() {
    return false;
  }
  isFIFO() {
    return false;
  }
  isSocket() {
    return false;
  }
}

class Dirent extends FileKind {
  constructor(raw) {
    super();
    this.name = raw.name;
    this.parentPath = raw.parentPath;
    this.path = raw.parentPath;
    this._isFile = raw._isFile;
    this._isDirectory = raw._isDirectory;
    this._isSymbolicLink = raw._isSymbolicLink;
  }
}

function fsPath(input) {
  // Search Recent Projects guards on a vscode-remote:// URI throwing ERR_INVALID_URL_SCHEME here.
  if (input instanceof URL) return fileURLToPath(input);
  if (input instanceof Uint8Array) return utf8Decode(input);
  return String(input);
}

// Node takes a mode as a number or as an octal string, and Raycast's Swift wrapper passes "755".
function fsMode(mode) {
  const parsed = typeof mode === "string" ? Number.parseInt(mode, 8) : Math.trunc(Number(mode));
  if (!Number.isFinite(parsed)) throw new TypeError(`Invalid file mode: ${mode}`);
  return parsed & 0o7777;
}

function statSync(file, options, lstat) {
  try {
    return new Stats(hostCallSync("fs", "stat", [fsPath(file), lstat]));
  } catch (error) {
    if (options?.throwIfNoEntry === false) return undefined;
    throw error;
  }
}

function checkBounds(buffer, offset, length, verb) {
  if (offset < 0 || length < 0 || offset + length > buffer.length) throw new RangeError(`${verb} exceeds buffer bounds`);
}

const FILE_STREAM_CHUNK = 64 * 1024;
const FS_CONSTANTS = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_APPEND: 8, O_NOFOLLOW: 256, O_CREAT: 512, O_TRUNC: 1024, O_EXCL: 2048 };
const { O_RDONLY, O_WRONLY, O_RDWR, O_APPEND, O_CREAT, O_TRUNC, O_EXCL } = FS_CONSTANTS;
const OPEN_FLAGS = {
  r: O_RDONLY, "r+": O_RDWR,
  w: O_WRONLY | O_CREAT | O_TRUNC, "w+": O_RDWR | O_CREAT | O_TRUNC,
  wx: O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, "wx+": O_RDWR | O_CREAT | O_TRUNC | O_EXCL,
  a: O_WRONLY | O_CREAT | O_APPEND, "a+": O_RDWR | O_CREAT | O_APPEND,
  ax: O_WRONLY | O_CREAT | O_APPEND | O_EXCL, "ax+": O_RDWR | O_CREAT | O_APPEND | O_EXCL,
};

export const fs = {
  constants: FS_CONSTANTS,

  openSync(file, flags = "r", mode = 0o666) {
    const value = typeof flags === "number" ? flags : OPEN_FLAGS[flags];
    if (value === undefined) throw new TypeError(`Invalid file flags: ${flags}`);
    return hostCallSync("fs", "open", [fsPath(file), value, fsMode(mode)]);
  },
  closeSync(fd) {
    hostCallSync("fs", "close", [fd]);
  },
  readSync(fd, buffer, offset = 0, length = buffer.length - offset, position = null) {
    checkBounds(buffer, offset, length, "Read");
    const bytes = base64ToBytes(hostCallSync("fs", "read", [fd, length, position]));
    buffer.set(bytes, offset);
    return bytes.length;
  },
  writeSync(fd, buffer, offset = 0, length = buffer.length - offset, position = null) {
    checkBounds(buffer, offset, length, "Write");
    return hostCallSync("fs", "write", [fd, bytesToBase64(buffer.subarray(offset, offset + length)), position]);
  },
  readFileSync(file, options) {
    const bytes = hostBuffer("fs", "readFile", [fsPath(file)]);
    const encoding = encodingOf(options);
    return encoding ? bytes.toString(encoding) : bytes;
  },
  writeFileSync(file, data, options) {
    hostCallSync("fs", "writeFile", [fsPath(file), encodeFileData(data, options), false]);
  },
  appendFileSync(file, data, options) {
    hostCallSync("fs", "writeFile", [fsPath(file), encodeFileData(data, options), true]);
  },
  existsSync(file) {
    try {
      return hostCallSync("fs", "exists", [fsPath(file)]);
    } catch {
      return false;
    }
  },
  statSync: (file, options) => statSync(file, options, false),
  lstatSync: (file, options) => statSync(file, options, true),
  readdirSync(dir, options) {
    const entries = hostCallSync("fs", "readdir", [fsPath(dir)]);
    if (options?.withFileTypes) return entries.map((entry) => new Dirent(entry));
    return entries.map((entry) => entry.name);
  },
  mkdirSync(dir, options) {
    return hostCallSync("fs", "mkdir", [fsPath(dir), !!(options === true || options?.recursive)]);
  },
  rmSync(target, options) {
    hostCallSync("fs", "remove", [fsPath(target), !!options?.recursive, !!options?.force]);
  },
  rmdirSync(target, options) {
    hostCallSync("fs", "remove", [fsPath(target), !!options?.recursive, false]);
  },
  unlinkSync(target) {
    hostCallSync("fs", "remove", [fsPath(target), false, false]);
  },
  renameSync(from, to) {
    hostCallSync("fs", "rename", [fsPath(from), fsPath(to)]);
  },
  copyFileSync(from, to) {
    hostCallSync("fs", "copyFile", [fsPath(from), fsPath(to)]);
  },
  realpathSync(target) {
    return hostCallSync("fs", "realpath", [fsPath(target)]);
  },
  accessSync(target) {
    if (!fs.existsSync(target)) {
      throw codedError(`ENOENT: no such file or directory, access '${fsPath(target)}'`, "ENOENT");
    }
  },
  mkdtempSync(prefix) {
    return hostCallSync("fs", "mkdtemp", [String(prefix)]);
  },
  chmodSync(file, mode) {
    hostCallSync("fs", "chmod", [fsPath(file), fsMode(mode)]);
  },
  utimesSync() {},
  futimesSync() {},
  watch: notSupported("fs.watch"),
  createReadStream(file, options) {
    const target = fsPath(file);
    const encoding = encodingOf(options);
    const span = options?.highWaterMark ?? FILE_STREAM_CHUNK;
    let offset = options?.start ?? 0;
    const stream = new Readable({
      highWaterMark: span,
      read() {
        try {
          const bytes = hostBuffer("fs", "readRange", [target, offset, span]);
          offset += bytes.length;
          this.push(bytes.length ? bytes : null);
        } catch (error) {
          this.destroy(error);
        }
      },
    });
    stream.path = target;
    if (encoding) stream.setEncoding(encoding);
    return stream;
  },
  // The host has no file handles, so each write is its own call: create once, then append.
  createWriteStream(file, options) {
    const target = fsPath(file);
    let append = options?.flags === "a" || options?.flags === "a+";
    const put = (data) => {
      hostCallSync("fs", "writeFile", [target, bytesToBase64(data), append]);
      append = true;
    };
    const stream = new Writable({
      write(chunk, encoding, callback) {
        const data = typeof chunk === "string" ? Buffer.from(chunk, encoding) : chunk;
        try {
          put(data);
        } catch (error) {
          return callback(error);
        }
        stream.bytesWritten += data.length;
        callback(null);
      },
      final(callback) {
        try {
          if (!append) put(new Uint8Array(0));
        } catch (error) {
          return callback(error);
        }
        callback(null);
      },
    });
    stream.bytesWritten = 0;
    stream.path = target;
    return stream;
  },
  opendirSync(dir) {
    return new Dir(fsPath(dir), fs.readdirSync(dir, { withFileTypes: true }));
  },
  Stats,
  Dirent,
};

// The host has no directory handles, so a Dir walks a snapshot taken when it was opened.
class Dir {
  #entries;
  #closed = false;
  constructor(path, entries) {
    this.path = path;
    this.#entries = entries;
  }
  #assertOpen() {
    if (this.#closed) throw codedError("Directory handle was closed", "ERR_DIR_CLOSED");
  }
  #settle(run, callback) {
    if (!callback) return (async () => run())();
    callbackify(run)(callback);
  }
  readSync() {
    this.#assertOpen();
    return this.#entries.shift() ?? null;
  }
  read(callback) {
    return this.#settle(() => this.readSync(), callback);
  }
  closeSync() {
    this.#assertOpen();
    this.#closed = true;
  }
  close(callback) {
    return this.#settle(() => this.closeSync(), callback);
  }
  async *[Symbol.asyncIterator]() {
    try {
      for (let entry = this.readSync(); entry; entry = this.readSync()) yield entry;
    } finally {
      if (!this.#closed) this.closeSync();
    }
  }
}
fs.Dir = Dir;

const PROMISED = [
  "readFile", "writeFile", "appendFile", "stat", "lstat", "readdir", "opendir", "mkdir", "rm", "rmdir",
  "unlink", "rename", "copyFile", "realpath", "access", "mkdtemp", "chmod",
];
for (const name of ["open", "close", "futimes", ...PROMISED]) fs[name] = callbackify(fs[`${name}Sync`]);
for (const name of ["read", "write"]) {
  fs[name] = (fd, buffer, offset, length, position, callback) => {
    callbackify(fs[`${name}Sync`])(fd, buffer, offset, length, position,
      (error, count) => callback(error, count, buffer));
  };
}
fs.exists = (file, callback) => queueMicrotask(() => callback(fs.existsSync(file)));

export const fsPromises = { constants: fs.constants };
for (const name of PROMISED) {
  const sync = fs[`${name}Sync`];
  fsPromises[name] = async (...args) => sync(...args);
}
fs.promises = fsPromises;
