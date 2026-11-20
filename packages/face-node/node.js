import { fileURLToPath } from "node:url";
import path from "node:path";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME } from "./codec.js";
import { makeFace, makeFaceDetector } from "./face.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const sdk = createNativeSdk({
  here: HERE,
  packageName: PACKAGE_NAME,
  modelId: MODEL_ID,
  coreName: "FaceNode",
});

export const Face = makeFace(sdk);
export const FaceDetector = makeFaceDetector(sdk);

export { FaceLibrary } from "./face.js";
export { Faceprint, Level } from "./faceprint.js";
