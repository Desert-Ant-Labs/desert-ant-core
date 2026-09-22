// The universal entry: import-safe for an SSR pass, and an honest refusal when a model is asked for.
import { makeAlign } from "./align.js";
import { PACKAGE_NAME } from "./codec.js";

// No version argument: the number lives in package.json, which only the native entry may read.
export const Align = makeAlign({
  open() {
    throw new Error(
      `${PACKAGE_NAME} has no browser/WebAssembly build: word-timestamp refinement runs a `
      + `two-graph cascade and the wasm host compiles one model per module. `
      + `On a server, import "${PACKAGE_NAME}/native".`);
  },
});
