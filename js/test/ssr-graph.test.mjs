// Regression guard for the SSR bundle graph.
//
// A framework renders a model package's universal wasm entry (browser.js) in
// Node for the Client-Component SSR pass, so the bundler follows the `#platform`
// seam's "default" condition into platform-node.js. If anything in that graph
// reaches the koffi native loader, the build dies before it ever runs: koffi
// ships native `.node` addons, and bundlers statically trace the lazy
// `require("koffi")` all the same (Turbopack: "non-ecmascript placeable asset:
// asset is not placeable in ESM chunks"). Shipping that edge broke
// @desert-ant-labs/emo 0.10.2 in Next.js.
//
// So: walk the static import graph the way a bundler would and assert koffi
// stays out of it.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const JS_DIR = path.dirname(fileURLToPath(new URL("../package.json", import.meta.url)));
const REPO = path.dirname(JS_DIR);

// The subpaths of @desert-ant-labs/core, as package.json "exports" maps them.
const CORE_ENTRIES = {
  "@desert-ant-labs/core": "index.js",
  "@desert-ant-labs/core/node": "node.js",
  "@desert-ant-labs/core/platform-node": "platform-node.js",
  "@desert-ant-labs/core/audio": "audio.js",
  "@desert-ant-labs/core/audio/node": "audio-node.js",
};

// Static `import ... from "x"`, `export ... from "x"`, and `require("x")`.
// Dynamic `import("x")` is deliberately included: bundlers chunk those too.
const SPECIFIERS = /(?:\b(?:from|import|require)\s*\(?\s*)["']([^"']+)["']/g;

// These files document the very edges this test forbids, so scan code only.
const stripComments = (src) =>
  src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");

function specifiersIn(file) {
  const src = stripComments(fs.readFileSync(file, "utf8"));
  return [...src.matchAll(SPECIFIERS)].map((m) => m[1]);
}

/** Every file and bare specifier a bundler reaches from `entry`. */
function moduleGraph(entry) {
  const files = new Set();
  const bare = new Set();
  const queue = [path.resolve(entry)];
  while (queue.length) {
    const file = queue.pop();
    if (files.has(file) || !fs.existsSync(file)) continue;
    files.add(file);
    for (const spec of specifiersIn(file)) {
      if (spec.startsWith(".")) {
        queue.push(path.resolve(path.dirname(file), spec));
      } else if (CORE_ENTRIES[spec]) {
        queue.push(path.join(JS_DIR, CORE_ENTRIES[spec]));
      } else {
        bare.add(spec);
      }
    }
  }
  return { files, bare };
}

function assertKoffiFree(entry, label) {
  const { files, bare } = moduleGraph(entry);
  assert.equal(bare.has("koffi"), false, `${label} must not reach koffi`);
  const native = [...files].filter((f) => f.endsWith(path.join("src", "native.js")));
  assert.deepEqual(native, [], `${label} must not reach the native loader`);
  const nodeEntry = [...files].filter((f) => f === path.join(JS_DIR, "node.js"));
  assert.deepEqual(nodeEntry, [], `${label} must not reach @desert-ant-labs/core/node`);
}

test("the core's SSR node seam never reaches koffi", () => {
  assertKoffiFree(path.join(JS_DIR, "platform-node.js"), "@desert-ant-labs/core/platform-node");
});

test("the browser entry never reaches koffi or node:*", () => {
  const { files, bare } = moduleGraph(path.join(JS_DIR, "index.js"));
  assert.equal(bare.has("koffi"), false, "browser entry must not reach koffi");
  const nodeBuiltins = [...bare].filter((s) => s.startsWith("node:"));
  assert.deepEqual(nodeBuiltins, [], "browser entry must not reach node: builtins");
  assert.ok(files.size > 1, "graph walked something");
});

// Each model package's SSR seam, walked from the package's own platform-node.js.
const packageDirs = fs
  .readdirSync(path.join(REPO, "packages"))
  .filter((d) => fs.existsSync(path.join(REPO, "packages", d, "platform-node.js")));

test("every model package ships an SSR seam", () => {
  assert.ok(packageDirs.length > 0, "found model node packages");
});

for (const dir of packageDirs) {
  test(`packages/${dir} SSR seam never reaches koffi`, () => {
    assertKoffiFree(path.join(REPO, "packages", dir, "platform-node.js"), `packages/${dir}`);
  });

  test(`packages/${dir} universal entry never reaches koffi`, () => {
    // browser.js resolves `#platform` -> platform-node.js under the "default"
    // condition, which is exactly what the SSR pass does.
    const entry = path.join(REPO, "packages", dir, "browser.js");
    const { files, bare } = moduleGraph(entry);
    assert.equal(bare.has("koffi"), false, `packages/${dir} browser entry must not reach koffi`);
    assert.equal(bare.has("#platform"), true, "browser entry goes through the platform seam");
    assertKoffiFree(path.join(REPO, "packages", dir, "platform-node.js"), `packages/${dir}`);
    assert.ok(files.size > 1, "graph walked something");
  });

  test(`packages/${dir} keeps koffi optional, not required`, () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(REPO, "packages", dir, "package.json"), "utf8"));
    assert.equal(pkg.dependencies?.koffi, undefined, "koffi is not a hard dependency");
    assert.equal(typeof pkg.optionalDependencies?.koffi, "string", "koffi is an optional dependency");
  });
}
