// Voz's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus ONNX Runtime Web on the bundle downloaded from
// the Hub, exactly as a consumer's first page load does. It must return
// something structured-cloneable, since the harness reads it back out of the
// page. `check` then runs in Node.
//
// The fixture is six seconds of a LibriVox recording (public domain), decoded
// from WAV bytes by the same path a consumer's `File` takes. See its README for
// why it starts where it does.

/** Resolved into the page's import map from this package's dependencies.
 *  Declared, not imported, because the package imports the runtime itself: the
 *  page still has to be able to resolve the bare specifier it asks for. */
export const imports = ["onnxruntime-web/webgpu"];

export async function run({ Voz }, { caseDir }) {
  const audio = await (await fetch(`${caseDir}/fixtures/speech.wav`)).arrayBuffer();

  // WebGPU where the adapter can actually run this encoder, the CPU where it
  // cannot. The shaders need `shader-f16`, and a machine with no GPU exposes a
  // software adapter without it, which fails to compile the session rather
  // than running it slowly - so a CI runner has to be told, not left to find
  // out. Everything above the provider is identical either way, which is what
  // this case is here to check.
  const adapter = await navigator.gpu?.requestAdapter();
  const ep = adapter?.features?.has("shader-f16") ? "webgpu" : "wasm";

  // No runtime passed: this is the browser path a consumer writes.
  const voz = await Voz.load({ ep });
  const result = await voz.transcribe(audio);
  return {
    text: result.text,
    duration: result.duration,
    realtimeFactor: result.realtimeFactor,
    // The point of the typed surface: words cross as objects, not a byte blob.
    words: result.words.slice(0, 8),
    wordCount: result.words.length,
    last: result.words[result.words.length - 1] ?? null,
    encoderCalls: voz.timings.calls.encoder,
    ep,
  };
}

export function check(result) {
  const text = result.text.toLowerCase();
  // What the recording says. Two words, so a single misrecognition does not
  // fail the run, and neither is a word the decoder could invent from silence.
  if (!text.includes("public domain") && !text.includes("volunteer")) {
    throw new Error(`expected the fixture's speech, got "${result.text}"`);
  }
  if (Math.abs(result.duration - 6) > 0.2) {
    throw new Error(`expected 6 s of audio, got ${result.duration}`);
  }
  if (!(result.wordCount > 5)) {
    throw new Error(`expected a handful of words, got ${result.wordCount}`);
  }

  // Word timestamps: the reason this surface is typed rather than a payload.
  for (const word of result.words) {
    if (typeof word.text !== "string" || !word.text.length) {
      throw new Error(`a word came back without text: ${JSON.stringify(word)}`);
    }
    if (!(word.start >= 0) || !(word.end >= word.start)) {
      throw new Error(`word "${word.text}" has a bad span ${word.start}..${word.end}`);
    }
    if (word.end > result.duration + 0.5) {
      throw new Error(`word "${word.text}" ends past the audio at ${word.end}`);
    }
  }
  const starts = result.words.map((w) => w.start);
  if (String(starts) !== String([...starts].sort((a, b) => a - b))) {
    throw new Error(`words are out of order: ${starts.join(" ")}`);
  }
  // A start of exactly zero for everything would satisfy the checks above and
  // mean the times never left the core.
  if (!(result.last && result.last.start > 0.5)) {
    throw new Error("the last word has no plausible time; timestamps did not cross");
  }
  if (!(result.encoderCalls > 0)) throw new Error("the encoder was never called");
  if (!["webgpu", "wasm"].includes(result.ep)) throw new Error(`odd provider ${result.ep}`);
  if (!(result.realtimeFactor > 0)) throw new Error("no realtime factor reported");
}
