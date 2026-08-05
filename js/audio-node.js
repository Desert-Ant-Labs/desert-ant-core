// Optional Node audio capability. Text-only model SDKs never import this entry.
export { installAudioHost } from "./src/audio-node.js";
export { decodeWav, mixdownMono, resampleLinear } from "./src/wav.js";
