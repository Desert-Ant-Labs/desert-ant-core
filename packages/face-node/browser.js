import * as platform from "#platform";
import { createWasmSdk } from "@desert-ant-labs/core";
import { PACKAGE_NAME } from "./codec.js";
import { makeFace, makeFaceDetector } from "./face.js";

const sdk = await createWasmSdk({
  platform,
  packageName: PACKAGE_NAME,
  defaultAccelerator: "auto",
});

export const Face = makeFace(sdk);
export const FaceDetector = makeFaceDetector(sdk);

export { FaceLibrary } from "./face.js";
export { Faceprint, Level } from "./faceprint.js";
export { DesertAnt } from "@desert-ant-labs/core";
