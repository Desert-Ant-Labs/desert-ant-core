// @desert-ant-labs/core/platform-node: the Node half of a model package's
// `#platform` seam, and nothing else. This is what the universal WebAssembly
// entry (a package's browser.js) reaches when a framework renders it in Node,
// e.g. Next.js's Client-Component SSR pass.
//
// It is deliberately separate from "@desert-ant-labs/core/node": that entry
// binds the prebuilt native core with koffi, and koffi ships native `.node`
// addons. Bundlers statically trace the `require("koffi")` inside the loader
// even though it only runs lazily, and then fail because a native addon cannot
// be placed in an ESM chunk (Turbopack: "non-ecmascript placeable asset").
// Keeping the two graphs apart means the SSR path pulls in `node:*` only.
export {
  nodeSetup,
  nodeWasmDir,
  nodeReadModelSource,
  nodeCacheRoot,
} from "./src/platform-node.js";
