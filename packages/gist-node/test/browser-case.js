// Gist's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on gist.tflite, with the model
// downloaded from the Hub exactly as a consumer's first page load does. It must
// return something structured-cloneable, since the harness reads it back out of
// the page. `check` then runs in Node.

export async function run({ Gist, channelTopics }, { litert, litertWasmDir }) {
  const gist = await Gist.load({ litert, litertWasmDir });
  try {
    const recipe = await gist.classify("A one-pan roast chicken recipe for weeknights");
    const spanish = await gist.classify("El equipo gana la final de la copa");
    const scores = await gist.scores("How to start a podcast with just your iPhone");
    const empty = await gist.classify("");
    // The roll-up ships in the same bundle, so exercise it in the browser too.
    const rolled = channelTopics(
      [{ topics: scores }, { topics: scores }, { topics: scores }],
      { topN: 3 });
    return {
      recipe: recipe.map((t) => t.slug),
      recipeNamed: recipe.every((t) => t.name.length > 0),
      spanish: spanish.map((t) => t.slug),
      taxonomySize: Object.keys(scores).length,
      topScore: recipe[0]?.score ?? 0,
      emptyCount: empty.length,
      rolledTop: rolled[0]?.slug ?? "",
    };
  } finally {
    gist.dispose();
  }
}

export function check(result) {
  // The same expectations the Swift and Kotlin suites assert, so "works in the
  // browser" means the same thing it means everywhere else.
  if (!result.recipe.includes("food-drink")) {
    throw new Error(`expected food-drink for the recipe, got ${result.recipe.join(" ")}`);
  }
  if (!result.recipeNamed) throw new Error("every topic must carry a display name");
  if (!result.spanish.includes("sports")) {
    throw new Error(`expected sports for the Spanish phrase, got ${result.spanish.join(" ")}`);
  }
  if (result.taxonomySize !== 36) {
    throw new Error(`expected the 36-topic taxonomy, got ${result.taxonomySize}`);
  }
  if (!(result.topScore > 0)) throw new Error(`expected a positive score, got ${result.topScore}`);
  if (result.emptyCount !== 0) throw new Error(`expected [] for empty input, got ${result.emptyCount} topics`);
  if (!result.rolledTop) throw new Error("channel roll-up returned nothing in the browser");
}
