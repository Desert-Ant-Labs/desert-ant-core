/**
 * Default platform binding: Node.
 *
 * The `browser` field in package.json remaps this module to
 * `platform.browser.js` for any bundler targeting the web, which is what keeps
 * `node:fs` out of a browser build. Node has no `browser` field, so it lands
 * here. The `browser` field is used rather than an `exports` condition because
 * webpack, esbuild, Vite and Rollup all honour it for file-level remapping.
 */
export * from "./platform.node.js";
