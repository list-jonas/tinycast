// Self-contained checks for the embedded runtime: each fixture is a tiny extension command compiled
// with esbuild exactly the way a real one is (CJS, JSX automatic, @raycast/api + react external).
//
//   node fixtures.mjs

import { createHarness, bootConfig, describeTree } from "./test.mjs";
import { transformSync } from "esbuild";

let passes = 0;
let failures = 0;

function check(label, condition, extra = "") {
  if (condition) {
    passes++;
    console.log(`  ✓ ${label}`);
  } else {
    failures++;
    console.log(`  ✗ ${label}${extra ? ` — ${extra}` : ""}`);
  }
}

function compile(source) {
  const { code } = transformSync(source, {
    loader: "jsx",
    jsx: "automatic",
    jsxImportSource: "react",
    format: "cjs",
    target: "es2022",
  });
  return code;
}

const wait = (ms = 60) => new Promise((resolve) => setTimeout(resolve, ms));

async function run(name, source, mode, verify) {
  console.log(`\n▶ ${name}`);
  const harness = createHarness();
  harness.boot(bootConfig());
  const code = compile(source);
  harness.start("s1", code, "/fixtures/cmd.js", "/fixtures", mode, {});
  await wait();
  await verify(harness);
  harness.stop("s1");
}

// ─── Fixtures ────────────────────────────────────────────────────────

const listSource = `
import { List, ActionPanel, Action, Icon } from "@raycast/api";
import { useState } from "react";

export default function Command() {
  const [count, setCount] = useState(0);
  return (
    <List
      searchBarPlaceholder="Search…"
      searchBarAccessory={
        <List.Dropdown tooltip="Filter" onChange={() => {}}>
          <List.Dropdown.Item title="All" value="all" />
          <List.Dropdown.Item title="Active" value="active" />
        </List.Dropdown>
      }
    >
      <List.Section title="Main">
        <List.Item
          id="item-1"
          title={"Count is " + count}
          accessories={[{ text: "Tag" }, { icon: Icon.Star }]}
          actions={
            <ActionPanel>
              <Action title="Bump" onAction={() => setCount((c) => c + 1)} />
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
`;

const detailSource = `
import { Detail } from "@raycast/api";

export default function Command() {
  return (
    <Detail
      markdown="# Hello world"
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Author" text="Ada" />
          <Detail.Metadata.Separator />
          <Detail.Metadata.TagList title="Tags">
            <Detail.Metadata.TagList.Item text="fast" color="#00ff00" />
          </Detail.Metadata.TagList>
          <Detail.Metadata.Link title="Link" target="https://example.com" text="Home" />
        </Detail.Metadata>
      }
    />
  );
}
`;

const fragmentDetailSource = `
import { List } from "@raycast/api";

export default function Command() {
  return (
    <List>
      <List.Item
        title="TOTP"
        detail={
          <>
            <List.Item.Detail markdown="30s remaining" />
            <List.Item.Detail metadata={<List.Item.Detail.Metadata><List.Item.Detail.Metadata.Label title="Code" text="123456" /></List.Item.Detail.Metadata>} />
          </>
        }
      />
    </List>
  );
}
`;

const formSource = `
import { Form, ActionPanel, Action } from "@raycast/api";

export default function Command() {
  return (
    <Form actions={<ActionPanel><Action.SubmitForm title="Save" onSubmit={(values) => { globalThis.__submitted = values; }} /></ActionPanel>}>
      <Form.TextField id="name" title="Name" defaultValue="Ada" />
      <Form.TextArea id="bio" title="Bio" defaultValue="" />
      <Form.Checkbox id="agree" label="I agree" defaultValue={true} />
      <Form.Dropdown id="role" title="Role" defaultValue="dev">
        <Form.Dropdown.Item value="dev" title="Developer" />
      </Form.Dropdown>
      <Form.TagPicker id="tags" title="Tags" defaultValue={["swift"]}>
        <Form.TagPicker.Item value="swift" title="Swift" />
      </Form.TagPicker>
      <Form.DatePicker id="when" title="When" defaultValue={new Date("2026-04-18T10:00:00Z")} />
      <Form.Separator />
      <Form.Description title="Info" text="All fields are saved locally." />
    </Form>
  );
}
`;

const navigationSource = `
import { List, ActionPanel, Action, useNavigation, Detail } from "@raycast/api";

function Subscreen() {
  return <Detail markdown="# Subscreen" />;
}

export default function Command() {
  const { push } = useNavigation();
  return (
    <List>
      <List.Item
        title="Push"
        actions={
          <ActionPanel>
            <Action title="Open subscreen" onAction={() => push(<Subscreen />)} />
          </ActionPanel>
        }
      />
    </List>
  );
}
`;

const nodeSource = `
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { Buffer } from "node:buffer";
import { Detail } from "@raycast/api";

export default function Command() {
  const parts = [
    path.join("/a/b", "../c", "d.txt"),
    path.extname("x/y/file.tar.gz"),
    path.basename("/a/b/c.md", ".md"),
    os.platform(),
    new URL("/next?q=1", "https://example.com/base/page").href,
    new URLSearchParams({ a: "1", b: "two words" }).toString(),
    crypto.createHash("sha256").update("abc").digest("hex").slice(0, 8),
    Buffer.from("hello").toString("base64"),
    Buffer.from("aGVsbG8=", "base64").toString("utf8"),
    new TextDecoder().decode(new TextEncoder().encode("héllo")),
  ];
  return <Detail markdown={parts.join("\\n")} />;
}
`;

// Bundled HTTP clients (axios) construct and probe a Response at module scope, before any component
// mounts — a host-shaped constructor took the whole command down with them.
// `node-fetch` is bundled into a large share of real extensions and never touches global `fetch`:
// it type-checks bodies against `stream`, then goes to the network through `http.request`.
const httpSource = `
import http from "node:http";
import https from "node:https";
import { types } from "node:util";
import Stream, { PassThrough, Readable, pipeline } from "node:stream";

export default async function Command() {
  const piped = await new Promise((resolve) => {
    const chunks = [];
    const out = pipeline(Readable.from("streamed body"), new PassThrough(), () => {});
    out.on("data", (chunk) => chunks.push(String(chunk)));
    out.on("end", () => resolve(chunks.join("")));
  });

  const response = await new Promise((resolve, reject) => {
    const request = http.request("https://example.com/api", { method: "GET" }, (message) => {
      const chunks = [];
      message.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      message.on("end", () =>
        resolve({ status: message.statusCode, body: Buffer.concat(chunks).toString("utf8"), headers: message.headers }));
    });
    request.on("error", reject);
    request.end();
  });

  // The shape node-fetch actually passes: a spread of this runtime's URL, whose host and search are
  // prototype getters — so no path survives the copy and the port arrives on its own.
  const spread = (url) => new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const call = http.request({ ...parsed, method: "GET" }, (message) => {
      message.on("data", () => {});
      message.on("end", () => resolve(message.url));
    });
    call.on("error", reject);
    call.end();
  });

  globalThis.__http = {
    piped,
    isStream: Readable.from("x") instanceof Stream,
    iterated: await (async () => { let text = ""; for await (const chunk of Readable.from("iterated")) text += chunk; return text; })(),
    status: response.status,
    body: response.body,
    spreadPath: await spread("https://example.com/api/tags?q=1"),
    spreadPort: await spread("https://example.com:8443/api"),
    // The scheme has to come from the module the call was made on: an http.request that defaulted
    // to https retargets every plain-options call, which is how localhost tooling is reached.
    plainProtocol: http.request({ hostname: "example.com", port: 8080, path: "/a" }).url,
    securedProtocol: https.request({ hostname: "example.com", path: "/a" }).url,
    // A host carries its port, and dropping it sends the request to 80 rather than erroring.
    hostPort: http.request({ host: "example.com:8443", path: "/a" }).url,
    // node-fetch v3 routes every Headers through these, so a missing one fails the first request
    // rather than the member — and reports it as a fetch failure far from the real cause.
    boxed: [new Number(1), new String("x"), Object(Symbol())].every(types.isBoxedPrimitive),
    unboxed: [1, "x", null, undefined, {}, new Date()].some(types.isBoxedPrimitive),
    // What a bundled client brand-checks a signal by, and both have to survive minification:
    // v2 reads the constructor's name, v3 the tag. Either one missing rejects the request before
    // it is made, so an AbortController fails the very fetch it was meant to cancel.
    signalName: Object.getPrototypeOf(new AbortController().signal).constructor.name,
    signalTag: new AbortController().signal[Symbol.toStringTag],
    anyArrayBuffer: types.isAnyArrayBuffer(new ArrayBuffer(2)) && !types.isAnyArrayBuffer(new Uint8Array(2)),
    // An empty body settles immediately, so its end fires before any listener can exist — which is
    // exactly the shape a child's stdout has. Node replays it; missing it hangs an execa-style read.
    lateEnd: await new Promise((resolve) => {
      const settled = new Readable();
      settled.push(null);
      setTimeout(() => {
        settled.on("data", () => {});
        settled.on("end", () => resolve("end"));
      }, 30);
      setTimeout(() => resolve("MISSED"), 400);
    }),
    encodingDropped: !("content-encoding" in response.headers),
    // The encoded length would describe bytes the caller never sees; the decoded one is the truth.
    length: response.headers["content-length"],
    bodyLength: String(Buffer.byteLength(response.body)),
    // A bodiless reply is measured by the body a GET would have returned, so a HEAD that reports
    // what arrived calls every response empty — and code sizing a download reads zero.
    headLength: await new Promise((resolve) => {
      const call = http.request("https://example.com/sized", { method: "HEAD" }, (message) => {
        message.on("data", () => {});
        message.on("end", () => resolve(message.headers["content-length"]));
      });
      call.on("error", (error) => resolve("error:" + error.message));
      call.end();
    }),
    // node-fetch v2 arms its timeout inside once("socket"), so a request that never reports one
    // silently drops the deadline the caller asked for.
    socketEmitted: await new Promise((resolve) => {
      const call = http.request("https://example.com/api", { method: "GET" });
      call.on("socket", () => resolve(true));
      call.end();
      setTimeout(() => resolve(false), 200);
    }),
    // Node hands back several Set-Cookie values as a list; folding them into one string makes a
    // cookie's own Expires comma impossible to split back out.
    cookies: response.headers["set-cookie"],
    timedOut: await new Promise((resolve) => {
      const slow = http.request("https://example.com/slow", { timeout: 30 });
      slow.on("timeout", () => resolve("timeout-event"));
      slow.on("error", () => {});
      slow.end();
      setTimeout(() => resolve("NEVER"), 600);
    }),
  };
}
`;

// A buffered child has already exited before any listener can attach, so `exit`/`close` replay.
// execa-shaped code drains stdout first and only then waits for the child, which would hang.
const spawnOrderSource = `
import { spawn } from "node:child_process";

export default async function Command() {
  const drainThenWait = async (arg) => {
    const child = spawn("/bin/echo", [arg]);
    let text = "";
    for await (const chunk of child.stdout) text += String(chunk);
    const closed = await Promise.race([
      new Promise((resolve) => child.on("close", (code) => resolve("close:" + code))),
      new Promise((resolve) => setTimeout(() => resolve("MISSED"), 900)),
    ]);
    return { text: text.trim(), closed };
  };

  const late = await drainThenWait("hi");
  const early = await new Promise((resolve) => {
    const child = spawn("/bin/echo", ["z"]);
    child.on("close", (code) => resolve("close:" + code));
  });

  const settled = spawn("/bin/echo", ["y"]);
  for await (const chunk of settled.stdout) String(chunk);
  let onceCalls = 0;
  settled.once("close", () => { onceCalls += 1; });
  await new Promise((resolve) => setTimeout(resolve, 250));

  globalThis.__spawnOrder = { late, early, onceCalls };
}
`;

// The failure modes a stream shim fails silently at: an import that dies on an interop probe, a
// destroyed stream that parks its reader forever, and a pipeline that reports a failure as success.
const streamEdgeSource = `
import * as web from "node:stream/web";
import { Readable, Transform, PassThrough, pipeline, finished, promises as sp } from "node:stream";

export default async function Command() {
  const race = (promise, label) =>
    Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve(label), 600))]);

  const drain = (stream) => (async () => {
    try {
      for await (const chunk of stream) String(chunk);
      return "returned";
    } catch (error) {
      return "threw:" + error.message;
    }
  })();

  const quiet = new Readable();
  setTimeout(() => quiet.destroy(), 20);
  const failed = new Readable();
  failed.on("error", () => {});
  setTimeout(() => failed.destroy(new Error("boom")), 20);

  // A torn-down stream reports close alone: an end here would tell a reader the body arrived.
  const torn = new Readable();
  const tornEvents = [];
  for (const event of ["end", "close"]) torn.on(event, () => tornEvents.push(event));
  torn.destroy();
  torn.resume();

  const settle = (stages) => new Promise((resolve) => {
    pipeline(...stages, (error) => resolve(error ? error.message : "null"));
    setTimeout(() => resolve("NEVER"), 600);
  });

  // A stream torn down mid-flight ends nothing, so every completion path has to answer on close.
  const abandoned = new Readable();
  abandoned.on("error", () => {});
  setTimeout(() => abandoned.destroy(), 20);
  const finishedOnDestroy = race(
    new Promise((resolve) => finished(abandoned, (error) => resolve(error ? error.code : "null"))),
    "HUNG",
  );
  const abandonedPipe = new Readable();
  abandonedPipe.on("error", () => {});
  setTimeout(() => abandonedPipe.destroy(), 20);
  const pipelineOnDestroy = race(
    sp.pipeline(abandonedPipe, new PassThrough()).then(() => "RESOLVED", (error) => error.code),
    "HUNG",
  );

  // Node's order, and each event exactly once: a duplicated close runs a consumer's teardown twice.
  const ordered = new PassThrough();
  const events = [];
  for (const event of ["finish", "end", "close"]) ordered.on(event, () => events.push(event));
  let finishedCalls = 0;
  finished(ordered, () => { finishedCalls += 1; });
  ordered.on("data", () => {});
  Readable.from("body").pipe(ordered);
  await new Promise((resolve) => setTimeout(resolve, 120));

  const late = new Readable();
  late.destroy();
  late.push("dropped");

  // A listener and an async iterator must each see the whole body: an iterator that shifts chunks
  // off the queue itself races the listener for them, and each side gets only the half it won.
  const shared2 = new Readable();
  shared2.push("s1"); shared2.push("s2"); shared2.push(null);
  const listened = [];
  shared2.on("data", (chunk) => listened.push(String(chunk)));
  let iterated2 = "";
  for await (const chunk of shared2) iterated2 += chunk;

  // A second consumer attaching in the same tick must see the body too: a synchronous drain on the
  // first listener empties the queue, which turns a tee into a stream only its first branch reads.
  const shared = new Readable();
  shared.push("shared"); shared.push(null);
  const seenA = [], seenB = [];
  shared.on("data", (chunk) => seenA.push(String(chunk)));
  shared.on("data", (chunk) => seenB.push(String(chunk)));

  // A chunk pushed while the first delivery is still pending must arrive behind the ones already
  // queued, not in front of them — a body reassembled out of order is corrupt in total silence.
  const ordering = new Readable();
  ordering.push("1"); ordering.push("2");
  const orderSeen = [];
  ordering.on("data", (chunk) => orderSeen.push(String(chunk)));
  ordering.push("3");
  ordering.push(null);

  // Node defers a destroy error, so the listener attached on the next line still catches it.
  const failedLate = new Readable();
  failedLate.destroy(new Error("late"));
  let lateError = "missed";
  failedLate.on("error", () => { lateError = "caught"; });

  // A stream that finished before finished() was called emits nothing further, so only its state
  // can answer — an event that has been and gone otherwise parks the caller for the whole session.
  const alreadyGone = new Readable();
  alreadyGone.on("error", () => {});
  alreadyGone.destroy();
  await new Promise((resolve) => setTimeout(resolve, 20));
  const finishedAfterTheFact = race(
    new Promise((resolve) => finished(alreadyGone, (error) => resolve(error ? error.code : "null"))),
    "HUNG",
  );
  await new Promise((resolve) => setTimeout(resolve, 40));

  globalThis.__streamEdge = {
    tee: seenA.join("") + "/" + seenB.join(""),
    ordering: orderSeen.join(""),
    listenerAndIterator: listened.join("") + "/" + iterated2,
    lateError,
    finishedAfterTheFact: await finishedAfterTheFact,
    webNames: ["ReadableStream", "WritableStream", "TransformStream"].every((name) => name in web),
    webThrows: (() => { try { web.ReadableStream; return false; } catch { return true; } })(),
    webProbe: web.__esModule === undefined && web.then === undefined,
    destroyed: await race(drain(quiet), "HUNG"),
    destroyedWithError: await race(drain(failed), "HUNG"),
    tornEvents: tornEvents.join(","),
    pipelineFailure: await settle([Readable.from("a"), new Transform({ transform: (c, e, cb) => cb(new Error("nope")) })]),
    pipelineSuccess: await settle([Readable.from("a"), new PassThrough()]),
    promisedFailure: await sp
      .pipeline(Readable.from("a"), new Transform({ transform: (c, e, cb) => cb(new Error("nope")) }))
      .then(() => "RESOLVED", (error) => error.message),
    finishedOnDestroy: await finishedOnDestroy,
    pipelineOnDestroy: await pipelineOnDestroy,
    events: events.join(","),
    finishedCalls,
    pushedAfterDestroy: late.readableLength ?? late._queue.length,
  };
}
`;

const responseSource = `
export default async function Command() {
  const probe = new Response();
  const created = new Response(JSON.stringify({ id: 7 }), {
    status: 201,
    statusText: "Created",
    headers: { "Content-Type": "application/json" },
  });
  const clone = created.clone();
  globalThis.__response = {
    probe: [probe.status, probe.ok, probe.statusText, await probe.text()],
    readers: ["text", "arrayBuffer", "blob"].every((name) => typeof probe[name] === "function"),
    created: [created.status, created.statusText, created.headers.get("content-type"), (await created.json()).id],
    clone: [clone.status, clone.headers.get("content-type"), await clone.text()],
    bytes: Array.from(await new Response(new Uint8Array([104, 105])).bytes()),
    byteLength: (await new Response("héllo").arrayBuffer()).byteLength,
  };
}
`;

const oauthSource = `
import { OAuth } from "@raycast/api";

export default async function Command() {
  const client = new OAuth.PKCEClient({
    redirectMethod: OAuth.RedirectMethod.Web,
    providerName: "GitHub",
    providerId: "github",
    description: "Connect your GitHub account",
  });

  const req = await client.authorizationRequest({
    endpoint: "https://github.com/login/oauth/authorize",
    clientId: "client-123",
    scope: "repo read:user",
  });

  const authRes = await client.authorize(req);

  const tokenSet = new OAuth.TokenSet({
    accessToken: "gho_secret123",
    refreshToken: "ghr_secret456",
    expiresIn: 3600,
  });

  await client.setTokens(tokenSet);
  const retrieved = await client.getTokens();

  const expiredToken = new OAuth.TokenSet({
    accessToken: "expired_token",
    expiresIn: 20,
    createdAt: Date.now() - 30000,
  });

  globalThis.__oauthTest = {
    verifierLen: req.codeVerifier.length,
    challengeLen: req.codeChallenge.length,
    stateLen: req.state.length,
    url: req.toURL(),
    authCode: authRes.authorizationCode,
    retrievedAccessToken: retrieved?.accessToken,
    retrievedRefreshToken: retrieved?.refreshToken,
    isExpiredLive: tokenSet.isExpired(),
    isExpiredOld: expiredToken.isExpired(),
  };

  await client.removeTokens();
  const afterRemove = await client.getTokens();
  globalThis.__oauthTest.afterRemove = afterRemove;
}
`;

const noViewSource = `
import { Clipboard, showHUD } from "@raycast/api";

export default async function Command() {
  await Clipboard.copy("from no-view");
  await showHUD("done");
  globalThis.__ranNoView = true;
}
`;

const asyncSource = `
import { List } from "@raycast/api";
import { useEffect, useState } from "react";

export default function Command() {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    const timer = setTimeout(() => {
      setItems(["alpha", "beta"]);
      setLoading(false);
    }, 20);
    return () => clearTimeout(timer);
  }, []);
  return (
    <List isLoading={loading}>
      {items.map((item) => <List.Item key={item} title={item} />)}
    </List>
  );
}
`;

const errorSource = `
export default function Command() {
  throw new Error("kaboom");
}
`;

// ─── Runner ─────────────────────────────────────────────────────────

export async function runFixtures() {
  await run("List with sections, actions and a dropdown", listSource, "view", async (harness) => {
    const tree = harness.state.trees.at(-1);
    const dump = tree ? describeTree(tree) : "";
    check("renders a screen", dump.includes("<__screen active=true>"));
    check("renders the List", dump.includes("<List"));
    check("keeps searchBarAccessory as a prop", dump.includes("searchBarAccessory=<List.Dropdown>"));
    check("renders a section with items", dump.includes("<List.Section") && dump.includes("<List.Item"));
    check("serializes accessories", dump.includes("accessories=[2]"));
    check("hoists actions into a prop", dump.includes("actions=<ActionPanel>"));
    check("defaults filtering to true", dump.includes("filtering=true"));

    // Bump the counter through the action's handler and confirm the re-render.
    const item = findNode(tree, "List.Item");
    const panel = item.props.actions;
    const bump = panel.children.find((child) => child.type === "Action");
    check("action carries a dispatchable handler", !!bump?.props?.onAction?.$fn, JSON.stringify(bump?.props));
    harness.dispatch("s1", bump.props.onAction.$fn);
    await wait();
    check("re-renders after the action", describeTree(harness.state.trees.at(-1)).includes("Count is 1"));
  });

  await run("Detail with metadata", detailSource, "view", async (harness) => {
    const dump = describeTree(harness.state.trees.at(-1));
    check("renders Detail", dump.includes("<Detail"));
    check("hoists metadata", dump.includes("metadata=<Detail.Metadata>"));
    const metadata = findNode(harness.state.trees.at(-1), "Detail").props.metadata;
    const kinds = metadata.children.map((child) => child.type);
    check(
      "metadata children in order",
      JSON.stringify(kinds) ===
        JSON.stringify([
          "Detail.Metadata.Label",
          "Detail.Metadata.Separator",
          "Detail.Metadata.TagList",
          "Detail.Metadata.Link",
        ]),
      JSON.stringify(kinds),
    );
  });

  await run("List.Item.Detail split across a Fragment", fragmentDetailSource, "view", async (harness) => {
    const detail = findNode(harness.state.trees.at(-1), "List.Item").props.detail;
    check("keeps the markdown from the first sibling", detail.props.markdown === "30s remaining", JSON.stringify(detail.props));
    check("keeps the metadata from the second sibling", detail.props.metadata?.type === "Detail.Metadata", JSON.stringify(detail.props));
  });

  await run("Form fields and submit", formSource, "view", async (harness) => {
    const tree = harness.state.trees.at(-1);
    const form = findNode(tree, "Form");
    const types = form.children.map((child) => child.type);
    check(
      "all field types render",
      ["Form.TextField", "Form.TextArea", "Form.Checkbox", "Form.Dropdown", "Form.TagPicker", "Form.DatePicker", "Form.Separator", "Form.Description"].every(
        (type) => types.includes(type),
      ),
      JSON.stringify(types),
    );
    const field = form.children.find((child) => child.type === "Form.TextField");
    check("field exposes its value", field.props.value === "Ada", JSON.stringify(field.props));
    check("field has a change handler", !!field.props.onTinycastChange?.$fn);

    harness.dispatch("s1", field.props.onTinycastChange.$fn, ["Grace"]);
    await wait();
    const submit = findNode(harness.state.trees.at(-1), "Action");
    harness.dispatch("s1", submit.props.onAction.$fn);
    await wait();
    const values = harness.call("globalThis.__submitted");
    check(
      "submit collects every field value",
      values?.name === "Grace" && values.agree === true && values.role === "dev" && Array.isArray(values.tags),
      JSON.stringify(values),
    );
  });

  await run("Navigation push and pop", navigationSource, "view", async (harness) => {
    const push = findNode(harness.state.trees.at(-1), "Action");
    harness.dispatch("s1", push.props.onAction.$fn);
    await wait();
    let screens = harness.state.trees.at(-1).children.filter((child) => child.type === "__screen");
    check("two screens after push", screens.length === 2, String(screens.length));
    check("the pushed screen is active", screens[1].props.active === true);
    check("the first screen is inactive but mounted", screens[0].props.active === false);
    check("navigation depth reported", harness.state.navigationDepth === 2, String(harness.state.navigationDepth));

    harness.call('__tinycast.popNavigation("s1")');
    await wait();
    screens = harness.state.trees.at(-1).children.filter((child) => child.type === "__screen");
    check("one screen after pop", screens.length === 1, String(screens.length));
  });

  await run("Node shims and web globals", nodeSource, "view", async (harness) => {
    const markdown = findNode(harness.state.trees.at(-1), "Detail").props.markdown.split("\n");
    const expected = [
      "/a/c/d.txt",
      ".gz",
      "c",
      "darwin",
      "https://example.com/next?q=1",
      "a=1&b=two+words",
      "ba7816bf",
      "aGVsbG8=",
      "hello",
      "héllo",
    ];
    expected.forEach((value, index) => check(`shim ${index}: ${value}`, markdown[index] === value, markdown[index]));
  });

  await run("node:http and node:stream carry node-fetch", httpSource, "no-view", async (harness) => {
    // The command makes several round trips and waits on a replayed `end`; 60ms lands mid-flight.
    await wait(300);
    const result = harness.call("JSON.stringify(globalThis.__http ?? null)");
    const http = result ? JSON.parse(result) : null;
    check("the command completed", !!http, harness.state.failures.join(" | "));
    if (!http) return;
    check("pipeline moves a body through a PassThrough", http.piped === "streamed body", http.piped);
    check("a Readable is an instance of Stream", http.isStream === true);
    check("a Readable can be consumed by async iteration", http.iterated === "iterated", http.iterated);
    check("http.request reaches the fetch bridge", http.status === 200, String(http.status));
    check("the response body arrives intact", http.body.startsWith("stubbed body"), http.body);
    check("a spread URL keeps its path and query", http.spreadPath === "https://example.com/api/tags?q=1", http.spreadPath);
    check("a spread URL names its port exactly once", http.spreadPort === "https://example.com:8443/api", http.spreadPort);
    check("a plain-options request keeps its module's scheme", http.plainProtocol === "http://example.com:8080/a", http.plainProtocol);
    check("https keeps its own scheme", http.securedProtocol === "https://example.com/a", http.securedProtocol);
    check("a port carried by host survives", http.hostPort === "http://example.com:8443/a", http.hostPort);
    check("a boxed primitive is recognised", http.boxed === true);
    check("a bare value is not called boxed", http.unboxed === false);
    check("a signal still names itself AbortSignal once minified", http.signalName === "AbortSignal", http.signalName);
    check("a signal carries the AbortSignal tag", http.signalTag === "AbortSignal", http.signalTag);
    check("isAnyArrayBuffer separates a buffer from its view", http.anyArrayBuffer === true);
    check("end reaches a listener that attached after the body", http.lateEnd === "end", http.lateEnd);
    check("the header describing the encoded body is dropped", http.encodingDropped === true);
    check("content-length matches the decoded body", http.length === http.bodyLength, `${http.length} vs ${http.bodyLength}`);
    check("a HEAD keeps the length of the body it describes", http.headLength === "4096", http.headLength);
    check("a request reports a socket, which arms node-fetch's timeout", http.socketEmitted === true);
    check("several Set-Cookie values stay separate", Array.isArray(http.cookies) && http.cookies.length === 2, JSON.stringify(http.cookies));
    check("a cookie's Expires comma survives the split", http.cookies?.[0]?.includes("Expires=Wed, 21 Oct 2099"), JSON.stringify(http.cookies?.[0]));
    // A cookie rebuilt from a parser keeps only the attributes that parser models, which turns an
    // expiring cookie into a session one — the values have to cross the bridge as they arrived.
    check("an attribute the parser drops still arrives", http.cookies?.[1]?.includes("Max-Age=3600"), JSON.stringify(http.cookies?.[1]));
    check("SameSite survives too", http.cookies?.[1]?.includes("SameSite=Strict"), JSON.stringify(http.cookies?.[1]));
    check("a request timeout is a real deadline", http.timedOut === "timeout-event", http.timedOut);
  });

  await run("a buffered child replays exit and close", spawnOrderSource, "no-view", async (harness) => {
    await wait(900);
    const raw = harness.call("JSON.stringify(globalThis.__spawnOrder ?? null)");
    const order = raw ? JSON.parse(raw) : null;
    check("the command completed", !!order, harness.state.failures.join(" | "));
    if (!order) return;
    check("stdout still drains", order.late.text === "hi", order.late.text);
    check("close reaches a listener attached after the drain", order.late.closed === "close:0", order.late.closed);
    check("close still reaches a listener attached before it fires", order.early === "close:0", order.early);
    check("a replayed once() fires exactly once", order.onceCalls === 1, String(order.onceCalls));
  });

  await run("streams fail loudly, never silently", streamEdgeSource, "no-view", async (harness) => {
    await wait(900);
    const raw = harness.call("JSON.stringify(globalThis.__streamEdge ?? null)");
    const edge = raw ? JSON.parse(raw) : null;
    check("the command completed", !!edge, harness.state.failures.join(" | "));
    if (!edge) return;
    check("stream/web survives an interop probe", edge.webProbe === true);
    check("stream/web still names the web streams", edge.webNames === true);
    check("stream/web throws on a real member", edge.webThrows === true);
    check("destroy() releases a parked reader", edge.destroyed === "returned", edge.destroyed);
    check("destroy(error) still reaches the reader", edge.destroyedWithError === "threw:boom", edge.destroyedWithError);
    check("a destroyed stream never claims it ended", edge.tornEvents === "close", edge.tornEvents);
    check("pipeline reports a stage that fails as it drains", edge.pipelineFailure === "nope", edge.pipelineFailure);
    check("pipeline still reports a clean run", edge.pipelineSuccess === "null", edge.pipelineSuccess);
    check("promises.pipeline rejects on failure", edge.promisedFailure === "nope", edge.promisedFailure);
    check("finished() answers a stream that was destroyed", edge.finishedOnDestroy === "ERR_STREAM_PREMATURE_CLOSE", edge.finishedOnDestroy);
    check("promises.pipeline rejects when a stage is destroyed", edge.pipelineOnDestroy === "ERR_STREAM_PREMATURE_CLOSE", edge.pipelineOnDestroy);
    check("a drained stream emits finish, end and close in order", edge.events === "finish,end,close", edge.events);
    check("finished() fires exactly once", edge.finishedCalls === 1, String(edge.finishedCalls));
    check("a chunk pushed after destroy is dropped", edge.pushedAfterDestroy === 0, String(edge.pushedAfterDestroy));
    check("every same-tick consumer sees the body", edge.tee === "shared/shared", edge.tee);
    check("a chunk pushed mid-delivery keeps its place", edge.ordering === "123", edge.ordering);
    check("a listener and an iterator both read the whole body", edge.listenerAndIterator === "s1s2/s1s2", edge.listenerAndIterator);
    check("a destroy error reaches a listener attached after it", edge.lateError === "caught", edge.lateError);
    check("finished() answers a stream that had already closed", edge.finishedAfterTheFact === "ERR_STREAM_PREMATURE_CLOSE", edge.finishedAfterTheFact);
  });

  await run("Response takes the Web spec's constructor", responseSource, "no-view", async (harness) => {
    const result = harness.call("globalThis.__response");
    const equals = (actual, expected) => JSON.stringify(actual) === JSON.stringify(expected);
    check("a zero-arg Response is a 200 with an empty body", equals(result.probe, [200, true, "", ""]), JSON.stringify(result.probe));
    check("exposes the body readers a feature probe looks for", result.readers === true);
    check("reads status, headers and JSON back", equals(result.created, [201, "Created", "application/json", 7]), JSON.stringify(result.created));
    check("clone carries status, headers and body", equals(result.clone, [201, "application/json", '{"id":7}']), JSON.stringify(result.clone));
    check("keeps a binary body intact", equals(result.bytes, [104, 105]), JSON.stringify(result.bytes));
    check("encodes a text body as UTF-8", result.byteLength === 6, String(result.byteLength));
  });

  await run("OAuth PKCEClient and TokenSet", oauthSource, "no-view", async (harness) => {
    const result = harness.call("globalThis.__oauthTest");
    check("generates PKCE codeVerifier and challenge", result?.verifierLen >= 43 && result?.challengeLen >= 43, JSON.stringify(result));
    check("generates OAuth state", result?.stateLen >= 20);
    check("builds correct authorization URL with redirect_uri", new URL(result.url).searchParams.get("redirect_uri") === "https://raycast.com/redirect?packageName=Extension" && new URL(result.url).searchParams.get("client_id") === "client-123");
    check("authorize returns authorization code", result?.authCode === "auth-code-12345");
    check("stores and retrieves TokenSet with tokens", result?.retrievedAccessToken === "gho_secret123" && result?.retrievedRefreshToken === "ghr_secret456");
    check("TokenSet isExpired calculation works", result?.isExpiredLive === false && result?.isExpiredOld === true);
    check("removeTokens cleans up tokens", result?.afterRemove === undefined || result?.afterRemove === null);
  });

  await run("no-view command", noViewSource, "no-view", async (harness) => {
    check("ran to completion", harness.state.finished === true);
    check("ran the body", harness.call("globalThis.__ranNoView") === true);
    check(
      "used the clipboard and HUD host calls",
      harness.state.hostCalls.includes("clipboard.copy") && harness.state.hostCalls.includes("feedback.showHUD"),
      harness.state.hostCalls.join(", "),
    );
  });

  await run("timers drive an async render", asyncSource, "view", async (harness) => {
    check("starts loading", describeTree(harness.state.trees[0]).includes("isLoading=true"));
    await wait(120);
    const dump = describeTree(harness.state.trees.at(-1));
    check("finishes loading", dump.includes("isLoading=false"), dump);
    check("renders the resolved items", dump.includes("alpha") && dump.includes("beta"));
  });

  console.log("\n▶ Errors surface instead of crashing");
  const harness = createHarness();
  harness.boot(bootConfig());
  harness.start("s1", compile(errorSource), "/fixtures/cmd.js", "/fixtures", "view", {});
  await wait();
  check("a throwing component reports a failure", harness.state.failures.some((message) => message.includes("kaboom")), harness.state.failures.join("|"));
  harness.stop("s1");

  console.log(failures === 0 ? "\nAll runtime fixtures passed." : `\n${failures} check(s) failed.`);
  if (import.meta.url === `file://${process.argv[1]}`) process.exit(failures === 0 ? 0 : 1);
  return failures;
}

function findNode(tree, type) {
  const stack = [...(tree?.children ?? [])];
  while (stack.length) {
    const node = stack.shift();
    if (node.type === type) return node;
    stack.push(...(node.children ?? []));
    // Slot props hold real nodes too (actions, metadata, detail).
    for (const value of Object.values(node.props ?? {})) {
      if (value && typeof value === "object" && value.type) stack.push(value);
      else if (Array.isArray(value)) stack.push(...value.filter((entry) => entry && entry.type));
    }
  }
  return undefined;
}

if (import.meta.url === `file://${process.argv[1]}`) await runFixtures();
