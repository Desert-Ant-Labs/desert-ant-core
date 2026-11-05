// Uhm's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on uhm.tflite, with the model
// downloaded from the Hub exactly as a consumer's first page load does. It must
// return something structured-cloneable. `check` then runs in Node.

export async function run({ Uhm, SAMPLE_RATE }, { litert, litertWasmDir }) {
  const uhm = await Uhm.load({ litert, litertWasmDir });
  try {
    const seconds = 4;
    const samples = new Float32Array(SAMPLE_RATE * seconds);
    for (let n = 0; n < samples.length; n++) {
      const t = n / SAMPLE_RATE;
      const syllable = 0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * t);
      samples[n] = syllable * 0.2 * Math.sin(2 * Math.PI * 180 * t);
    }
    const result = await uhm.detect(samples, SAMPLE_RATE, {
      words: [{ start: 0.2, end: 0.6, text: "hello" }, { start: 2, end: 2, text: "void" }],
    });
    return {
      audioDuration: result.audioDuration,
      fillerCount: result.fillers.length,
      fillersInRange: result.fillers.every((f) => f.start >= 0 && f.end <= seconds && f.end > f.start),
      confidencesInRange: result.fillers.every((f) => f.confidence > 0 && f.confidence <= 1),
      words: result.words,
    };
  } finally {
    uhm.dispose();
  }
}

export function check(result) {
  // Synthetic audio proves the path, not the model: accuracy is measured in the
  // training repo's bench. What must hold here is the contract every SDK shares.
  if (Math.abs(result.audioDuration - 4) > 0.05) throw new Error(`duration ${result.audioDuration}, expected 4`);
  if (!result.fillersInRange) throw new Error("a filler span lies outside the audio");
  if (!result.confidencesInRange) throw new Error("a confidence is outside 0..1");
  if (!Array.isArray(result.words)) throw new Error("words were sent but none came back");
  if (result.words.some((w) => w.end <= w.start)) throw new Error("a zero-duration word survived reconciliation");
}
