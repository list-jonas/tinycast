// Self-contained checks for the embedded runtime, one file per surface under fixtures/.
//
//   node fixtures.mjs

import { runComponentFixtures } from "./fixtures/components.mjs";
import { tally } from "./fixtures/kit.mjs";
import { runNodeFixtures } from "./fixtures/node.mjs";
import { runWebFixtures } from "./fixtures/web.mjs";

export async function runFixtures() {
  await runComponentFixtures();
  await runNodeFixtures();
  await runWebFixtures();
  const { failures } = tally;
  console.log(failures === 0 ? "\nAll runtime fixtures passed." : `\n${failures} check(s) failed.`);
  if (import.meta.url === `file://${process.argv[1]}`) process.exit(failures === 0 ? 0 : 1);
  return failures;
}

if (import.meta.url === `file://${process.argv[1]}`) await runFixtures();
