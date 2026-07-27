import { test } from "node:test";
import assert from "node:assert/strict";

// Skeleton suite: the native core is only present after `mise run node-natives`,
// so this asserts the package surface rather than running inference. Replace with
// real tests once the pipeline is implemented.

test("exports the public class", async () => {
  const mod = await import("../node.js");
  assert.equal(typeof mod.__PRODUCT__, "function");
  assert.equal(typeof mod.__PRODUCT__.load, "function");
});
