// The `./native` entry, and the package's only working one: the prebuilt Swift core, loaded by koffi.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeAlign } from "./align.js";
import pkg from "./package.json" with { type: "json" };

const HERE = path.dirname(fileURLToPath(import.meta.url));

export const Align = makeAlign(createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "AlignNode",
}), pkg.version);
