// Runtime fixtures for the web globals: Response, fetch bodies, FormData, streams and OAuth.

import { check, reply, run, same } from "./kit.mjs";

// Bundled HTTP clients (axios) construct and probe a Response at module scope, before any component
// mounts — a host-shaped constructor took the whole command down with them.
const responseSource = `
export default async function Command() {
  const probe = new Response();
  const created = new Response(JSON.stringify({ id: 7 }), {
    status: 201,
    statusText: "Created",
    headers: { "Content-Type": "application/json" },
  });
  const clone = created.clone();
  const abort = new DOMException("stopped", "AbortError");
  const blob = new Blob(["hello", new Uint8Array([33])], { type: "Text/Plain" });
  const slice = blob.slice(1, 4, "Application/Test");
  const responseBlob = await new Response("hi", { headers: { "Content-Type": "text/custom" } }).blob();
  globalThis.__response = {
    probe: [probe.status, probe.ok, probe.statusText, await probe.text()],
    readers: ["text", "arrayBuffer", "blob"].every((name) => typeof probe[name] === "function"),
    created: [created.status, created.statusText, created.headers.get("content-type"), (await created.json()).id],
    clone: [clone.status, clone.headers.get("content-type"), await clone.text()],
    bytes: Array.from(await new Response(new Uint8Array([104, 105])).bytes()),
    byteLength: (await new Response("héllo").arrayBuffer()).byteLength,
    blob: [blob.size, blob.type, await blob.text(), Array.from(await blob.bytes()).join(",")],
    slice: [slice.size, slice.type, await slice.text(), await new Response(blob).text()],
    responseBlob: [responseBlob.size, responseBlob.type, await responseBlob.text()],
    domException: [abort.name, abort.message, abort instanceof Error, abort instanceof DOMException, new DOMException().name],
  };
}
`;

// A URLSearchParams body sets no header of its own, so the spec's derived Content-Type is the only
// thing an OAuth token endpoint has: without it Google reads the form body as JSON and rejects it.
const contentTypeSource = `
export default async function Command() {
  const url = "https://example.test/token";
  const send = (init) => fetch(url, { method: "POST", ...init });
  await send({ body: new URLSearchParams({ client_id: "abc" }) });
  await send({ body: "ping" });
  await send({ body: new Blob(["z"], { type: "Application/Zip" }) });
  await send({ body: new Blob(["z"]) });
  await send({ body: new URLSearchParams({ client_id: "abc" }), headers: { "Content-Type": "application/json" } });
  await send({});
  const request = new Request(url, { method: "POST", body: new URLSearchParams({ a: "1" }) });
  globalThis.__contentType = request.headers.get("content-type");
}
`;

// gaxios reaches for `FormData` on every request, so it has to exist; and a form that exists but
// serialises to nothing would be worse than one that is absent, so the body has to be real too.
const formDataSource = `
export default async function Command() {
  const form = new FormData();
  form.append("name", "Ada");
  form.append("tag", "one");
  form.append("tag", "two");
  form.append("file", new Blob(["hi"], { type: "Text/Plain" }), "note.txt");
  form.append("blobless", new Blob(["x"]));
  const shape = {
    get: form.get("tag"),
    getAll: form.getAll("tag"),
    has: [form.has("name"), form.has("missing")],
    entryNames: Array.from(form.keys()),
    file: [form.get("file").name, form.get("file").type, await form.get("file").text()],
    defaultName: form.get("blobless").name,
    isFile: form.get("file") instanceof File,
  };
  form.set("tag", "only");
  form.delete("blobless");
  shape.afterSet = Array.from(form.keys());
  shape.afterSetValue = form.getAll("tag");

  await fetch("https://example.test/upload", { method: "POST", body: form });
  const explicit = new FormData();
  explicit.append("a", "1");
  await fetch("https://example.test/upload", { method: "POST", body: explicit, headers: { "Content-Type": "text/custom" } });
  globalThis.__form = shape;
}
`;

// The Homebrew extension streams its package index to disk rather than buffering it: it guards on
// `response.body`, counts bytes through a `TransformStream`, and pipes the result into a file — then
// reads it back through a `Transform`. Issue #429: `Response` had no `body`, so it failed at "HTTP 200".
const streamSource = `
import fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable, Transform, Writable } from "node:stream";
import { pipeline } from "node:stream/promises";

export default async function Command() {
  const target = join(tmpdir(), "tinycast-fixture-index.json");
  const response = await fetch("https://example.test/index.json");
  if (!response.ok || !response.body) throw new Error(\`HTTP \${response.status}: \${response.statusText}\`);

  let observed = 0;
  const counter = new TransformStream({
    transform(chunk, controller) {
      observed += chunk.length;
      controller.enqueue(chunk);
    },
  });
  const sink = fs.createWriteStream(target);
  await pipeline(Readable.fromWeb(response.body.pipeThrough(counter)), sink);

  const upper = new Transform({
    transform(chunk, encoding, done) {
      done(null, chunk.toString().toUpperCase());
    },
  });
  const read = [];
  const collect = new Writable({
    write(chunk, encoding, done) {
      read.push(chunk.toString());
      done(null);
    },
  });
  await pipeline(fs.createReadStream(target), upper, collect);

  globalThis.__stream = {
    observed,
    bytesWritten: sink.bytesWritten,
    onDisk: fs.readFileSync(target, "utf8"),
    piped: read.join(""),
  };
  fs.unlinkSync(target);
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
    updatedAt: new Date(Date.now() - 30000),
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

// `@raycast/utils` stores the provider's raw token response, which carries no timestamp, so the
// stored time is the only thing `isExpired()` can count from; without it a token never expired.
const tokenExpirySource = `
import { OAuth } from "@raycast/api";

export default async function Command() {
  const client = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "Google", providerId: "google" });
  await client.setTokens({ access_token: "ya29.a", refresh_token: "1//r", expires_in: 3599, token_type: "Bearer" });
  const fresh = await client.getTokens();
  const realNow = Date.now;
  Date.now = () => realNow() + 2 * 3600 * 1000;
  const laterExpired = (await client.getTokens()).isExpired();
  Date.now = realNow;
  const unstamped = new OAuth.PKCEClient({ redirectMethod: OAuth.RedirectMethod.Web, providerName: "Old", providerId: "unstamped" });
  const legacy = await unstamped.getTokens();
  globalThis.__expiry = {
    freshExpired: fresh.isExpired(),
    freshStampedNow: fresh.updatedAt instanceof Date && Math.abs(fresh.updatedAt.getTime() - realNow()) < 5000,
    laterExpired,
    unstampedExpired: legacy.isExpired(),
  };
}
`;

export async function runWebFixtures() {
  await run("Response takes the Web spec's constructor", responseSource, "no-view", async (harness) => {
    const result = harness.call("globalThis.__response");
    check("a zero-arg Response is a 200 with an empty body", same(result.probe, [200, true, "", ""]), JSON.stringify(result.probe));
    check("exposes the body readers a feature probe looks for", result.readers === true);
    check("reads status, headers and JSON back", same(result.created, [201, "Created", "application/json", 7]), JSON.stringify(result.created));
    check("clone carries status, headers and body", same(result.clone, [201, "application/json", '{"id":7}']), JSON.stringify(result.clone));
    check("keeps a binary body intact", same(result.bytes, [104, 105]), JSON.stringify(result.bytes));
    check("encodes a text body as UTF-8", result.byteLength === 6, String(result.byteLength));
    check(
      "provides Blob bytes and text semantics",
      same(result.blob, [6, "text/plain", "hello!", "104,101,108,108,111,33"]),
      JSON.stringify(result.blob),
    );
    check("slices Blob data and accepts it as a Response body", same(result.slice, [3, "application/test", "ell", "hello!"]), JSON.stringify(result.slice));
    check("creates a typed Blob from Response.blob", same(result.responseBlob, [2, "text/custom", "hi"]), JSON.stringify(result.responseBlob));
    check("DOMException is an Error carrying its name", same(result.domException, ["AbortError", "stopped", true, true, "Error"]), JSON.stringify(result.domException));
  });

  const sentTypes = [];
  await run("fetch derives Content-Type from the body", contentTypeSource, "no-view", async (harness) => {
      check("sends every request", sentTypes.length === 6, String(sentTypes.length));
      check("URLSearchParams implies form encoding", sentTypes[0] === "application/x-www-form-urlencoded;charset=UTF-8", String(sentTypes[0]));
      check("a string implies text/plain", sentTypes[1] === "text/plain;charset=UTF-8", String(sentTypes[1]));
      check("a Blob carries its own type", sentTypes[2] === "application/zip", String(sentTypes[2]));
      check("an untyped Blob implies nothing", sentTypes[3] === undefined, String(sentTypes[3]));
      check("an explicit header wins", sentTypes[4] === "application/json", String(sentTypes[4]));
      check("a bodiless request implies nothing", sentTypes[5] === undefined, String(sentTypes[5]));
      check("Request exposes the derived header", harness.call("globalThis.__contentType") === "application/x-www-form-urlencoded;charset=UTF-8");
    },
    {
      stubs: {
        "fetch.request": (args) => {
          sentTypes.push(args[0].headers["content-type"]);
          return reply("https://example.test/token");
        },
      },
    },
  );

  const formPosts = [];
  await run("FormData holds entries and serialises as multipart", formDataSource, "no-view", async (harness) => {
      const shape = harness.call("globalThis.__form");
      check("get returns the first value", shape.get === "one", JSON.stringify(shape.get));
      check("getAll returns every value", same(shape.getAll, ["one", "two"]), JSON.stringify(shape.getAll));
      check("has distinguishes present from absent", same(shape.has, [true, false]), JSON.stringify(shape.has));
      check("keys preserve insertion order", same(shape.entryNames, ["name", "tag", "tag", "file", "blobless"]), JSON.stringify(shape.entryNames));
      check("a Blob entry becomes a named File", same(shape.file, ["note.txt", "text/plain", "hi"]), JSON.stringify(shape.file));
      check("an unnamed Blob entry defaults to \"blob\"", shape.defaultName === "blob", String(shape.defaultName));
      check("a Blob entry is a File instance", shape.isFile === true, String(shape.isFile));
      check("set replaces every value in place", same(shape.afterSet, ["name", "tag", "file"]), JSON.stringify(shape.afterSet));
      check("set collapses duplicates to one", same(shape.afterSetValue, ["only"]), JSON.stringify(shape.afterSetValue));

      const [posted, explicit] = formPosts;
      const boundary = (posted.type ?? "").split("boundary=")[1];
      check("derives multipart with a boundary", !!boundary && posted.type.startsWith("multipart/form-data; boundary="), String(posted.type));
      check("the body uses the header's boundary", posted.body.startsWith(`--${boundary}\r\n`), posted.body.slice(0, 60));
      check("a string part carries only its name", posted.body.includes(`Content-Disposition: form-data; name="name"\r\n\r\nAda`), posted.body.slice(0, 200));
      check("a File part carries filename and type", posted.body.includes(`name="file"; filename="note.txt"\r\nContent-Type: text/plain`), posted.body);
      check("the body ends with the closing boundary", posted.body.endsWith(`--${boundary}--\r\n`), posted.body.slice(-40));
      check("an explicit Content-Type still wins", explicit.type === "text/custom", String(explicit.type));
    },
    {
      stubs: {
        "fetch.request": (args) => {
          formPosts.push({ type: args[0].headers["content-type"], body: Buffer.from(args[0].bodyBase64 ?? "", "base64").toString() });
          return reply("https://example.test/upload");
        },
      },
    },
  );

  const indexBody = JSON.stringify(Array.from({ length: 4000 }, (_, index) => ({ name: `pkg-${index}` })));
  await run("a fetch body streams through a transform onto disk", streamSource, "no-view", async (harness) => {
      const result = harness.call("globalThis.__stream");
      check("the response exposes a body stream", result !== undefined && result.observed > 0, JSON.stringify(result));
      check("every byte reaches the transform", result?.observed === indexBody.length, `${result?.observed} of ${indexBody.length}`);
      check("every byte reaches the file", result?.bytesWritten === indexBody.length, String(result?.bytesWritten));
      check("the file matches the response", result?.onDisk === indexBody);
      check("reading it back through a Transform preserves it", result?.piped === indexBody.toUpperCase());
    },
    {
      stubs: {
        "fetch.request": () =>
          reply("https://example.test/index.json", {
            headers: { "content-type": "application/json", "content-length": String(indexBody.length) },
            bodyBase64: Buffer.from(indexBody).toString("base64"),
          }),
      },
    },
  );

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

  const storedTokens = new Map([["unstamped", JSON.stringify({ access_token: "ya29.old", expires_in: 3599 })]]);
  await run("a stored token expires from the time it was stored", tokenExpirySource, "no-view", async (harness) => {
      const result = harness.call("globalThis.__expiry");
      check("a just-stored token is not expired", result?.freshExpired === false, JSON.stringify(result));
      check("setTokens stamps updatedAt with the storage time", result?.freshStampedNow === true, JSON.stringify(result));
      check("the same token two hours later is expired", result?.laterExpired === true, JSON.stringify(result));
      check("a stored token with no timestamp counts as expired", result?.unstampedExpired === true, JSON.stringify(result));
    },
    {
      stubs: {
        "oauth.setTokens": (args) => {
          storedTokens.set(args[0], args[1]);
          return null;
        },
        "oauth.getTokens": (args) => storedTokens.get(args[0]) ?? null,
      },
    },
  );
}
