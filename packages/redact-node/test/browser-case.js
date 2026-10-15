// Redact's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on the redact model, downloaded from
// the Hub exactly as a consumer's first page load does. It must return something
// structured-cloneable, since the harness reads it back out of the page. `check`
// then runs in Node.

const LONG =
  "Hi team, quick update on the Henderson account. I spoke with Rachel Adams this morning " +
  "and she confirmed the renewal. Tom Becker from finance will send the invoice on Friday. " +
  "If anything changes, ping me or Olivia Park. Thanks, Daniel";
const LONG_NAMES = ["Rachel", "Adams", "Tom", "Becker", "Olivia", "Park", "Daniel"];

export async function run({ Redact }, { litert, litertWasmDir }) {
  const redact = await Redact.load({ litert, litertWasmDir });
  try {
    const text =
      "Hi, I'm Anna Kowalska. Email me at anna.k@example.com or call +1 (555) 010-4477. " +
      "Card: 4539 1488 0343 6467.";
    const result = await redact.redaction(text);
    // Multi-sentence text goes through sentence chunking, which must hold on
    // the wasm + LiteRT.js path as well as the native ones.
    const long = await redact.redaction(LONG);
    return {
      longRedacted: long.redactedText,
      longRestored: long.restore(long.redactedText),
      redactedText: result.redactedText,
      labels: result.items.map((item) => String(item.label)),
      // Reversibility is the product promise, so prove it survives the round
      // trip in the browser too, not just that spans were found.
      restored: result.restore(result.redactedText),
      original: text,
    };
  } finally {
    redact.dispose();
  }
}

export function check(result) {
  for (const name of LONG_NAMES) {
    if (result.longRedacted.includes(name)) {
      throw new Error(`${name} leaked from multi-sentence text: ${result.longRedacted}`);
    }
  }
  if (result.longRestored !== LONG) {
    throw new Error(`restore() did not round-trip multi-sentence text: ${result.longRestored}`);
  }
  if (!/\[GIVEN_NAME_1\]/.test(result.redactedText)) {
    throw new Error(`expected a redacted given name, got: ${result.redactedText}`);
  }
  if (!/\[EMAIL_1\]/.test(result.redactedText)) {
    throw new Error(`expected a redacted email, got: ${result.redactedText}`);
  }
  if (result.redactedText.includes("anna.k@example.com")) {
    throw new Error("the email survived redaction");
  }
  // Reversibility is the product promise: the placeholders must map back to the
  // originals, and none may be left behind.
  if (!result.restored.includes("anna.k@example.com") || !result.restored.includes("Anna")) {
    throw new Error(`restore() did not bring the originals back: ${result.restored}`);
  }
  if (/\[[A-Z_]+_\d+\]/.test(result.restored)) {
    throw new Error(`restore() left a placeholder behind: ${result.restored}`);
  }
}
