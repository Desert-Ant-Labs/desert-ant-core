// Run from an installed tarball: proves the package name resolves and both load paths work.
import { Align } from "@desert-ant-labs/align/native";

const words = [{ text: "hola", start: 0.4, end: 0.71 }, { text: "mundo", start: 0.8, end: 1.3 }];

function tone(seconds = 3, sampleRate = 16000) {
  const out = new Float32Array(seconds * sampleRate);
  for (let i = 0; i < out.length; i++) out[i] = 0.3 * Math.sin((2 * Math.PI * 200 * i) / sampleRate);
  return out;
}

async function refineWith(label, options) {
  const align = await Align.load(options);
  try {
    const out = await align.refine(tone(), 16000, words, { language: "es" });
    if (out.length !== words.length) throw new Error(`${label}: got ${out.length} words`);
    console.log(`${label}: downloaded=${align.isDownloaded()} refined=${out.map((w) => w.refined).join(",")}`);
  } finally {
    align.dispose();
  }
}

const dir = process.env.ALIGN_FIXTURE_DIR;
if (!dir) throw new Error("set ALIGN_FIXTURE_DIR to a populated model directory");

console.log(`sdkVersion ${Align.sdkVersion} on ${process.platform}-${process.arch}`);
// Core ML on darwin, LiteRT on linux; the native core picks it, the JS never names a file.
console.log(`backend ${process.platform === "darwin" ? "coreml" : "litert"}`);
await refineWith("directory", { directory: dir });
await refineWith("download", {});
await refineWith("cache", {});
console.log("clean-install OK");
