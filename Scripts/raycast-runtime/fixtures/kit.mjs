// Shared plumbing for the runtime fixtures: compile a command exactly the way a real extension is
// built (CJS, JSX automatic, @raycast/api + react external), run it in the harness, check the result.

import { transformSync } from "esbuild";
import { bootConfig, createHarness, describeTree } from "../test.mjs";

export { describeTree };

export const tally = { passes: 0, failures: 0 };

export function check(label, condition, extra = "") {
  if (condition) {
    tally.passes++;
    console.log(`  ✓ ${label}`);
  } else {
    tally.failures++;
    console.log(`  ✗ ${label}${extra ? ` — ${extra}` : ""}`);
  }
}

export const same = (actual, expected) => JSON.stringify(actual) === JSON.stringify(expected);

export const wait = (ms = 60) => new Promise((resolve) => setTimeout(resolve, ms));

/// What the bridge answers a stubbed `fetch.request` with: a 200 and an empty body unless overridden.
export const reply = (url, overrides = {}) => ({ status: 200, statusText: "OK", headers: {}, url, bodyBase64: "", ...overrides });

function compile(source) {
  return transformSync(source, { loader: "jsx", jsx: "automatic", jsxImportSource: "react", format: "cjs", target: "es2022" }).code;
}

export async function run(name, source, mode, verify, options) {
  console.log(`\n▶ ${name}`);
  const harness = createHarness(options);
  harness.boot(bootConfig());
  harness.start("s1", compile(source), "/fixtures/cmd.js", "/fixtures", mode, {});
  await wait(options?.settle);
  await verify(harness);
  harness.stop("s1");
}

export function findNode(tree, type) {
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
