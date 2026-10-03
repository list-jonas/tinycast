// Runtime fixtures for the Node builtins: path/fs/url shims, child processes, http, dgram, websockets and load-time surfaces.

import { check, findNode, reply, run } from "./kit.mjs";

const nodeSource = `
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import crypto from "node:crypto";
import { Buffer } from "node:buffer";
import { fileURLToPath, pathToFileURL } from "node:url";
import { Detail } from "@raycast/api";

export default function Command() {
  const errorCode = (fn) => {
    try {
      fn();
      return "none";
    } catch (error) {
      return error.code ?? error.name;
    }
  };
  const cpu = os.cpus()[0];
  const parts = [
    path.join("/a/b", "../c", "d.txt"),
    path.extname("x/y/file.tar.gz"),
    path.basename("/a/b/c.md", ".md"),
    os.platform(),
    Object.keys(cpu.times).sort().join(","),
    String(Object.values(cpu.times).every(Number.isFinite)),
    String(os.freemem() > 0),
    String(os.uptime() > 0),
    String(os.loadavg().length === 3 && os.loadavg().every(Number.isFinite)),
    new URL("/next?q=1", "https://example.com/base/page").href,
    new URLSearchParams({ a: "1", b: "two words" }).toString(),
    crypto.createHash("sha256").update("abc").digest("hex").slice(0, 8),
    Buffer.from("hello").toString("base64"),
    Buffer.from("aGVsbG8=", "base64").toString("utf8"),
    new TextDecoder().decode(new TextEncoder().encode("héllo")),
    fileURLToPath("file:///Applications/Tinycast%20Beta.app"),
    fileURLToPath(new URL("file:///tmp/%ED%95%9C%EA%B8%80.txt")),
    fileURLToPath("file://localhost/tmp/a?query=ignored#fragment"),
    fileURLToPath("file:///tmp/a%5Cb"),
    fileURLToPath("file:tmp/a"),
    fileURLToPath("file:///tmp/%2e%2e/a"),
    fileURLToPath("file://%6cocalhost/tmp/a"),
    fileURLToPath("file:///tmp//a"),
    fileURLToPath(new URL("file:///tmp/a///b")),
    fileURLToPath("file:///tmp/a//../b"),
    fileURLToPath("file:///C:/.."),
    new URL(
      "file:///tmp/a?query=" +
        String.fromCharCode(92) +
        "keep#fragment=" +
        String.fromCharCode(92) +
        "keep",
    ).href,
    new URL("https://example.com/C:/..").href,
    fileURLToPath("file:///a:folder/.."),
    new URL("..", "file:///a:folder/child").href,
    new URL("..", "https://example.com/C:/child").href,
    pathToFileURL("/tmp/My Image.png").href,
    pathToFileURL("/tmp/a#b.png").href,
    fileURLToPath(pathToFileURL("/tmp/a#b.png")),
    fileURLToPath(pathToFileURL("/tmp/a?b.png")),
    fileURLToPath(pathToFileURL("/Applications/Tinycast Beta.app")),
    errorCode(() => fileURLToPath("file:///tmp/a%2Fb")),
    errorCode(() => fileURLToPath("file://a%2Fb/tmp/a")),
    errorCode(() => fileURLToPath("file://example.com/tmp/a")),
    errorCode(() => fileURLToPath("https://example.com/a")),
    errorCode(() => fileURLToPath({})),
    errorCode(() => fileURLToPath("file://user@localhost/tmp/a")),
    errorCode(() => fileURLToPath("file://localhost:/tmp/a")),
    errorCode(() => fileURLToPath("file:///C:/a", { windows: true })),
    // fs validates URL schemes the way Node does: a vscode-remote:// workspace URI whose stripped
    // pathname exists locally ("/" always does) must not pass existsSync — Raycast's Search Recent
    // Projects relies on that guard before handing the URI to fileURLToPath.
    String(fs.existsSync(new URL("vscode-remote://ssh-remote%2Bucg/"))),
    String(fs.existsSync(new URL("vscode-remote://ssh-remote%2Bserver/etc/docker/daemon.json"))),
    String(fs.existsSync(new URL("file:///etc/hosts"))),
    String(fs.existsSync("/etc/hosts")),
    errorCode(() => fs.statSync(new URL("https://example.com/a"))),
    errorCode(() => fs.readFileSync(new URL("https://example.com/a"))),
  ];
  return <Detail markdown={parts.join("\\n")} />;
}
`;

// A child's output arrives in one go once the process has already exited, so both ways of reading a
// stream have to work after the fact: `execa` async-iterates stdout, others attach a `data` listener.
const spawnSource = `
import { spawn } from "node:child_process";

export default async function Command() {
  const iterated = [];
  const child = spawn("/bin/echo", ["hello"]);
  for await (const chunk of child.stdout) iterated.push(chunk.toString());

  const late = await new Promise((resolve) => {
    const other = spawn("/bin/echo", ["world"]);
    other.on("close", () => {
      const chunks = [];
      other.stdout.on("data", (chunk) => chunks.push(chunk.toString()));
      other.stdout.on("end", () => resolve(chunks.join("")));
    });
  });

  // Port Manager detaches lsof to get a killable process group, then reads its output.
  const grouped = await new Promise((resolve) => {
    const child = spawn("/bin/echo", ["group"], { detached: true, stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    child.stdout.on("data", (chunk) => chunks.push(chunk.toString()));
    child.on("close", () => resolve(chunks.join("")));
  });

  const streamed = await new Promise((resolve) => {
    const events = [];
    const child = spawn("/bin/sh", ["-c", "echo a; sleep 0.2; echo b"]);
    child.on("spawn", () => events.push("spawn"));
    child.stdout.once("data", () => events.push(child.exitCode === null ? "live" : "after-exit"));
    child.on("close", () => resolve(events.join(",")));
  });

  globalThis.__spawn = { iterated: iterated.join(""), late, grouped, streamed };
}
`;

// node-fetch travels inside `@raycast/utils` and drives `http.request` rather than global `fetch`,
// then reads the response back by async-iterating a stream it pipes through a `PassThrough`.
const httpSource = `
import http from "node:http";
import stream, { PassThrough, pipeline } from "node:stream";

export default async function Command() {
  globalThis.__http = await new Promise((resolve, reject) => {
    const request = http.request(
      "https://example.test/data",
      { method: "post", headers: { "X-Probe": ["one", "two"], "Accept-Encoding": "gzip, deflate, br" } },
      async (response) => {
        const body = pipeline(response, new PassThrough(), () => {});
        const chunks = [];
        for await (const chunk of body) chunks.push(chunk.toString());
        resolve({
          status: response.statusCode,
          statusText: response.statusMessage,
          contentType: response.headers["content-type"],
          decoding: [response.headers["content-encoding"], response.headers["content-length"]],
          isStream: body instanceof stream,
          text: chunks.join(""),
        });
      },
    );
    request.on("error", reject);
    request.end("ping");
  });
}
`;

// Hide My Email hands axios a cookie jar through axios-cookiejar-support, whose http-cookie-agent
// extends `http.Agent` at load time and hooks each request in `addRequest` — the same way this does.
// A bundled `ws` reaches the network the way this does: upgrade, then raw frames on the socket.
// multicast-dns drives `dgram` the way this does, down to the packet it writes.
const dgramSource = `
import dgram from "node:dgram";

function query(name, type) {
  const labels = name.split(".");
  const packet = Buffer.alloc(12 + labels.reduce((total, label) => total + label.length + 1, 1) + 4);
  packet.writeUInt16BE(0x1234, 0);
  packet.writeUInt16BE(1, 4);
  let offset = 12;
  for (const label of labels) {
    packet[offset] = label.length;
    packet.write(label, offset + 1);
    offset += label.length + 1;
  }
  packet.writeUInt16BE(type, offset + 1);
  packet.writeUInt16BE(1, offset + 3);
  return packet;
}

export default async function Command() {
  const socket = dgram.createSocket({ type: "udp4" });
  globalThis.__dgram = await new Promise((resolve) => {
    socket.on("message", (message, rinfo) => resolve({ hex: message.toString("hex"), port: rinfo.port }));
    socket.bind(5353, undefined, () => {
      const service = query("_services._dns-sd._udp.local", 12);
      socket.send(service, 0, service.length, 5353, "224.0.0.251");
      const packet = query("homeassistant.local", 1);
      socket.send(packet, 0, packet.length, 5353, "224.0.0.251");
    });
  });
}
`;

const websocketSource = `
import https from "node:https";

export default async function Command() {
  globalThis.__ws = await new Promise((resolve, reject) => {
    const request = https.request({
      host: "example.test",
      path: "/socket",
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Extensions": "permessage-deflate",
      },
    });
    request.on("error", reject);
    request.on("upgrade", (response, socket) => {
      const frames = [];
      socket.on("data", (chunk) => frames.push(chunk.toString("hex")));
      const payload = Buffer.from("ping", "utf8");
      const mask = Buffer.from([1, 2, 3, 4]);
      socket.write(
        Buffer.concat([
          Buffer.from([0x81, 0x80 | payload.length]),
          mask,
          Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4])),
        ]),
      );
      socket.write(Buffer.from([0x89, 0x80, 1, 2, 3, 4]));
      setTimeout(
        () =>
          resolve({
            status: response.statusCode,
            accept: response.headers["sec-websocket-accept"],
            extensions: response.headers["sec-websocket-extensions"] ?? null,
            frames,
          }),
        40,
      );
    });
    request.end();
  });
}
`;

// A member `__toESM` cannot see lands as an opaque `The superclass is not a constructor`.
const undiciSurfaceSource = `
import diagnostics from "node:diagnostics_channel";
import { markAsUncloneable } from "node:worker_threads";
import { getHashes } from "node:crypto";

class Ping extends Event {
  constructor() {
    super("ping", { cancelable: true });
  }
}

export default async function Command() {
  const request = diagnostics.channel("undici:request:create");
  const idle = request.hasSubscribers;
  const published = [];
  diagnostics.subscribe("undici:request:create", (message, name) => published.push([message.id, name]));
  request.publish({ id: 1 });

  const target = new EventTarget();
  const calls = [];
  target.addEventListener("ping", () => calls.push("once"), { once: true });
  target.addEventListener("ping", { handleEvent: (event) => { calls.push(event.target === target); event.preventDefault(); } });
  const notCancelled = target.dispatchEvent(new Ping());
  target.dispatchEvent(new Ping());

  const { port1, port2 } = new MessageChannel();
  port1.postMessage({ n: 1 });
  let delivered = false;
  const received = new Promise((resolve) => port2.addEventListener("message", (event) => resolve((delivered = true) && event.data)));
  const early = delivered;
  const data = await received;

  globalThis.__undiciSurface = {
    idle,
    subscribed: request.hasSubscribers,
    published,
    guarded: typeof (markAsUncloneable || null),
    hashes: getHashes(),
    calls,
    notCancelled,
    data,
    early,
  };
}
`;

const namespaceImportSource = `
import * as net from "node:net";
import * as vm from "node:vm";
import { AsyncResource } from "node:async_hooks";
import { Socket } from "node:net";

class Tracked extends AsyncResource {
  constructor() {
    super("tracked");
    this.seen = [];
  }
  record(value) {
    return this.runInAsyncScope(() => {
      this.seen.push(value);
      return this.seen.length;
    });
  }
}

export default async function Command() {
  const refusal = (fn) => {
    try {
      fn();
      return "none";
    } catch (error) {
      return error.message;
    }
  };
  const tracked = new Tracked();
  globalThis.__namespaceImport = {
    kinds: [typeof net.Socket, typeof Socket, typeof vm.Script, typeof AsyncResource],
    keys: Object.keys(net).filter((key) => key !== "default"),
    refusals: [refusal(() => new net.Socket()), refusal(() => vm.runInNewContext("1"))],
    scope: [tracked.record("a"), tracked.record("b"), tracked.seen.join("")],
    type: tracked.type,
  };
}
`;

const cookieAgentSource = `
import * as http from "node:http";
import * as url from "node:url";

class CookieAgent extends http.Agent {
  constructor(options) {
    super(options);
    this.jar = new Map();
  }

  addRequest(request, options) {
    const target = url.format({ host: request.host, pathname: request.path, protocol: request.protocol });
    const implicitHeader = request._implicitHeader.bind(request);
    request._implicitHeader = () => {
      if (this.jar.size) request.setHeader("Cookie", [...this.jar].map(([k, v]) => k + "=" + v).join("; "));
      implicitHeader();
    };
    const emit = request.emit.bind(request);
    request.emit = (event, ...args) => {
      if (event === "response") {
        for (const line of args[0].headers["set-cookie"] ?? []) {
          const [pair] = line.split(";");
          const [name, value] = pair.split("=");
          this.jar.set(name, value);
        }
        this.urls.push(target);
      }
      return emit(event, ...args);
    };
    super.addRequest(request, options);
  }
}

const send = (agent, path) =>
  new Promise((resolve, reject) => {
    const request = http.request("https://example.test" + path, { agent }, (response) => {
      response.resume();
      response.on("end", () => resolve(response));
    });
    request.on("error", reject);
    request.end();
  });

export default async function Command() {
  const agent = new CookieAgent({ keepAlive: true });
  agent.urls = [];
  const first = await send(agent, "/signin?step=1");
  await send(agent, "/account");
  globalThis.__cookieAgent = {
    isAgent: agent instanceof http.Agent,
    setCookie: first.headers["set-cookie"],
    rawHeaders: first.rawHeaders,
    urls: agent.urls,
  };
}
`;

export async function runNodeFixtures() {
  await run("Node shims and web globals", nodeSource, "view", async (harness) => {
    const markdown = findNode(harness.state.trees.at(-1), "Detail").props.markdown.split("\n");
    const expected = [
      "/a/c/d.txt", ".gz", "c", "darwin", "idle,irq,nice,sys,user", "true", "true", "true", "true",
      "https://example.com/next?q=1", "a=1&b=two+words", "ba7816bf", "aGVsbG8=", "hello", "héllo",
      "/Applications/Tinycast Beta.app", "/tmp/한글.txt", "/tmp/a", "/tmp/a\\b", "/tmp/a", "/a", "/tmp/a",
      "/tmp//a", "/tmp/a///b", "/tmp/a/b", "/C:/", String.raw`file:///tmp/a?query=\keep#fragment=\keep`,
      "https://example.com/", "/a:folder/", "file:///a:folder/", "https://example.com/",
      "file:///tmp/My%20Image.png", "file:///tmp/a%23b.png", "/tmp/a#b.png", "/tmp/a?b.png",
      "/Applications/Tinycast Beta.app", "ERR_INVALID_FILE_URL_PATH", "ERR_INVALID_URL",
      "ERR_INVALID_FILE_URL_HOST", "ERR_INVALID_URL_SCHEME", "ERR_INVALID_ARG_TYPE", "ERR_INVALID_URL",
      "ERR_INVALID_URL", "Error", "false", "false", "true", "true", "ERR_INVALID_URL_SCHEME",
      "ERR_INVALID_URL_SCHEME",
    ];
    expected.forEach((value, index) => check(`shim ${index}: ${value}`, markdown[index] === value, markdown[index]));
  });

  await run("spawn's stdout survives a late reader", spawnSource, "no-view", async (harness) => {
    const result = harness.call("globalThis.__spawn");
    check("async iteration collects stdout", result?.iterated === "hello\n", JSON.stringify(result?.iterated));
    check("a listener attached after exit still gets it", result?.late === "world\n", JSON.stringify(result?.late));
    check("a detached child that pipes stdout is still awaited", result?.grouped === "group\n", JSON.stringify(result?.grouped));
    check("output streams before exit, after spawn", result?.streamed === "spawn,live", JSON.stringify(result?.streamed));
  }, { settle: 800 });

  const httpSpecs = [];
  await run("http.request rides the same bridge as fetch", httpSource, "no-view", async (harness) => {
      const result = harness.call("globalThis.__http");
      const spec = httpSpecs[0] ?? {};
      check("sends one request over the fetch bridge", httpSpecs.length === 1, String(httpSpecs.length));
      check("uppercases the method", spec.method === "POST", String(spec.method));
      check("joins a multi-valued header", spec.headers?.["x-probe"] === "one, two", JSON.stringify(spec.headers));
      check("leaves content negotiation to the transport", spec.headers?.["accept-encoding"] === undefined);
      check("forwards the written body", Buffer.from(spec.bodyBase64 ?? "", "base64").toString() === "ping");
      check("reports status and message", result.status === 201 && result.statusText === "Created");
      check("keeps the other headers", result.contentType === "application/json", String(result.contentType));
      check("drops headers describing bytes the bridge already decoded", JSON.stringify(result.decoding) === "[null,null]", JSON.stringify(result.decoding));
      check("the body is a Stream", result.isStream === true);
      check("delivers the body to a late reader", result.text === '{"ok":true}', result.text);
    },
    {
      stubs: {
        "fetch.request": (args) => {
          httpSpecs.push(args[0]);
          return {
            status: 201,
            statusText: "Created",
            headers: { "content-type": "application/json", "content-encoding": "gzip", "content-length": "31" },
            url: "https://example.test/data",
            bodyBase64: Buffer.from('{"ok":true}').toString("base64"),
          };
        },
      },
    },
  );

  const lookups = [];
  await run("dgram answers an mDNS query out of the resolver", dgramSource, "no-view", async (harness) => {
      const result = harness.call("globalThis.__dgram");
      check("resolves the name the query asked for", lookups[0] === "homeassistant.local", String(lookups[0]));
      check("leaves a service question alone", lookups.length === 1, JSON.stringify(lookups));
      check("answers the query it was sent", result?.hex?.startsWith("123484000001000100000000"), String(result?.hex));
      check("names the host in the answer", result?.hex?.includes("0d686f6d65617373697374616e74056c6f63616c00"), String(result?.hex));
      check("carries the address as an A record", result?.hex?.endsWith("00010001000000780004c0a801e2"), String(result?.hex));
    },
    {
      stubs: {
        "dns.resolve": (args) => {
          lookups.push(args[0]);
          return ["192.168.1.226"];
        },
      },
    },
  );

  const socketOpens = [];
  const socketSends = [];
  let socketReads = 0;
  let socketPings = 0;
  await run("a websocket upgrade hands back a socket that frames both ways", websocketSource, "no-view", async (harness) => {
      const result = harness.call("globalThis.__ws");
      check("opens the native socket over wss", socketOpens[0]?.url === "wss://example.test/socket", JSON.stringify(socketOpens[0]?.url));
      check("drops the handshake headers", socketOpens[0]?.headers?.upgrade === undefined, JSON.stringify(socketOpens[0]?.headers));
      check("reports the upgrade", result?.status === 101, String(result?.status));
      check("answers the key the way a server would", result?.accept === "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", String(result?.accept));
      check("never accepts an extension", result?.extensions === null, String(result?.extensions));
      check("unmasks an outgoing frame", socketSends[0]?.text === "ping", JSON.stringify(socketSends[0]));
      check("frames an incoming message", result?.frames?.[0] === "8104706f6e67", JSON.stringify(result?.frames));
      check("asks the peer before answering a ping", socketPings === 1, String(socketPings));
      check("pongs once the peer answered", result?.frames?.includes("8a00"), JSON.stringify(result?.frames));
    },
    {
      stubs: {
        "websocket.open": (args) => {
          socketOpens.push(args[0]);
          return { id: 7, protocol: "" };
        },
        "websocket.send": (args) => {
          socketSends.push(args[0]);
          return null;
        },
        "websocket.ping": () => {
          socketPings++;
          return null;
        },
        // The second read never settles, which is what an idle socket looks like from JS.
        "websocket.receive": () => (socketReads++ === 0 ? { type: "text", text: "pong" } : new Promise(() => {})),
      },
    },
  );

  await run("undici's load-time surface is real", undiciSurfaceSource, "no-view", async (harness) => {
    const result = harness.call("globalThis.__undiciSurface");
    check("a fresh channel has no subscribers", result?.idle === false, JSON.stringify(result));
    check("a subscriber receives what the channel publishes", JSON.stringify(result?.published) === JSON.stringify([[1, "undici:request:create"]]), JSON.stringify(result?.published));
    check("a channel reports its subscriber", result?.subscribed === true, String(result?.subscribed));
    check("markAsUncloneable is a function, so an || guard is moot", result?.guarded === "function", String(result?.guarded));
    check("getHashes lists the digests the host computes", JSON.stringify(result?.hashes) === JSON.stringify(["md5", "sha1", "sha256", "sha384", "sha512"]), JSON.stringify(result?.hashes));
    check("a once listener fires once and handleEvent sees the target", JSON.stringify(result?.calls) === JSON.stringify(["once", true, true]), JSON.stringify(result?.calls));
    check("preventDefault cancels a cancelable event", result?.notCancelled === false, String(result?.notCancelled));
    check("a port delivers a clone after posting returns", result?.data?.n === 1 && result?.early === false, JSON.stringify(result));
  });

  await run("a namespace import keeps the shim's named members", namespaceImportSource, "no-view", async (harness) => {
    const result = harness.call("globalThis.__namespaceImport");
    const kinds = JSON.stringify(result?.kinds);
    check("every member survives the own-key snapshot", kinds === JSON.stringify(["function", "function", "function", "function"]), kinds);
    check("net enumerates its exports", result?.keys?.includes("Socket") && result.keys.includes("createConnection"), JSON.stringify(result?.keys));
    check("an unsupported member still refuses by name", result?.refusals?.[0]?.startsWith("net.Socket is not supported"), JSON.stringify(result?.refusals));
    check("a refusal names the member that was called", result?.refusals?.[1]?.startsWith("vm.runInNewContext is not supported"), JSON.stringify(result?.refusals));
    check("AsyncResource runs the callback in place", JSON.stringify(result?.scope) === JSON.stringify([1, 2, "ab"]), JSON.stringify(result?.scope));
    check("AsyncResource keeps its type", result?.type === "tracked", String(result?.type));
  });

  const cookieSpecs = [];
  const cookies = ["a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/", "b=2; Path=/"];
  await run("an http.Agent subclass carries cookies between requests", cookieAgentSource, "no-view", async (harness) => {
      const result = harness.call("globalThis.__cookieAgent");
      const setCookie = JSON.stringify(result?.setCookie);
      const rawHeaders = JSON.stringify(result?.rawHeaders);
      const urls = JSON.stringify(result?.urls);
      const sent = cookieSpecs[1]?.headers;
      check("http.Agent survives esbuild's namespace import", result?.isAgent === true, JSON.stringify(result));
      check("splits a folded Set-Cookie without cutting its Expires date", setCookie === JSON.stringify(cookies), setCookie);
      check("rawHeaders repeats the name per cookie", rawHeaders === JSON.stringify(cookies.flatMap((c) => ["set-cookie", c])), rawHeaders);
      check("url.format builds the request URL from its parts", result?.urls?.[0] === "https://example.test/signin%3Fstep=1", urls);
      check("the second request sends every cookie the first received", sent?.cookie === "a=1; b=2", JSON.stringify(sent));
    },
    {
      stubs: {
        "fetch.request": (args) => {
          cookieSpecs.push(args[0]);
          const headers = cookieSpecs.length === 1 ? { "set-cookie": cookies.join(", ") } : {};
          return reply(args[0].url, { headers });
        },
      },
    },
  );
}
