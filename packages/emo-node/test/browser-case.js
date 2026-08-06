// Emo's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on emo.tflite, with the model
// downloaded from the Hub exactly as a consumer's first page load does. It must
// return something structured-cloneable, since the harness reads it back out of
// the page. `check` then runs in Node.

export async function run({ Emo }, { litert, litertWasmDir }) {
  const emo = await Emo.load({ litert, litertWasmDir });
  try {
    const bills = await emo.suggestions("Pay my bills", { limit: 5 });
    const dog = await emo.suggestions("walk the dog", { limit: 5 });
    const empty = await emo.suggestions("");
    return {
      bills: bills.map((s) => s.emoji),
      dog: dog.map((s) => s.emoji),
      topConfidence: bills[0]?.confidence ?? 0,
      emptyCount: empty.length,
    };
  } finally {
    emo.dispose();
  }
}

export function check(result) {
  // The same expectations the Swift and Kotlin suites assert, so "works in the
  // browser" means the same thing it means everywhere else.
  const money = ["💰", "💳", "🧾", "🏦", "📄"];
  if (!result.bills.some((e) => money.includes(e))) {
    throw new Error(`expected a money emoji for "Pay my bills", got ${result.bills.join(" ")}`);
  }
  if (!result.dog.length) throw new Error('no suggestions for "walk the dog"');
  if (!(result.topConfidence > 0)) throw new Error(`expected a positive confidence, got ${result.topConfidence}`);
  if (result.emptyCount !== 0) throw new Error(`expected [] for empty input, got ${result.emptyCount} suggestions`);
}
