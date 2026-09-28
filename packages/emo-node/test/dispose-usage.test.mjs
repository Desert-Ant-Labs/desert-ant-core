// Disposing a model sends or carries only its own pending usage, within the re-emit window, without blocking.
import assert from "node:assert/strict";
import { test } from "node:test";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { availableParallelism } from "node:os";

const CHILD = fileURLToPath(new URL("./dispose-child.mjs", import.meta.url));
// Each child gets a throwaway home of its own, as every test process does.
const SETUP = fileURLToPath(new URL("../../../js/test/setup.mjs", import.meta.url));

let available = true;
try {
  const { Emo } = await import("../node.js");
  (await Emo.load()).dispose();
} catch {
  available = false;
}
// Skipped locally when the model cannot load; in CI that is a failure.
const opts = available || process.env.CI ? {} : { skip: "native emo model unavailable" };

function scenario(name, env = {}) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, ["--import", SETUP, CHILD], { env: { ...process.env, ...env, SCENARIO: name }, timeout: 60_000 }, (error, stdout, stderr) => {
      if (error) reject(new Error(`${name}: ${error.message}\n${stderr.slice(-400)}`));
      else {
        const line = /^RESULT (.*)$/m.exec(stdout);
        if (line) resolve(JSON.parse(line[1]));
        else reject(new Error(`${name}: no result in ${stdout.slice(-400)}`));
      }
    });
  });
}

test("a dispose inside the window carries the call instead of posting a new load", opts, async () => {
  const result = await scenario("window");
  assert.deepEqual(result.afterCycle0, [[1]], "the first dispose did not send its turnstile");
  assert.deepEqual(result.afterCycle1, [[1]], "the second dispose posted inside the window");
});

test("disposing one model sends nothing for another model's session", opts, async () => {
  const result = await scenario("isolation");
  assert.equal(result.afterDisposeA, 1, "disposing A sent for B too");
  assert.equal(result.afterDisposeB, 1, "B's call, inside the window, was posted rather than carried");
});

test("a dispose during an in-flight flushTelemetry() returns promptly", opts, async () => {
  const result = await scenario("dispose-during-flush");
  assert.ok(result.disposeMs < 200, `dispose took ${Math.round(result.disposeMs)} ms`);
});

test("a dispose returns promptly while every Swift pool thread is busy with inference", opts, async () => {
  // A libuv pool wider than the core count, so the concurrent runs really occupy every Swift pool thread.
  const threads = String(availableParallelism() * 2 + 4);
  const result = await scenario("saturated", { UV_THREADPOOL_SIZE: threads });
  assert.ok(result.disposeMs < 250, `dispose took ${Math.round(result.disposeMs)} ms`);
});
