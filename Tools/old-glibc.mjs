// Run by mise's test:node-old-glibc inside ubuntu:20.04, from an install of the packed tarballs.
import assert from "node:assert/strict";

const args = process.argv.slice(2);
const noLibcurl = args[0] === "--no-libcurl";
const models = noLibcurl ? args.slice(1) : args;
assert.ok(models.length, "no models given");

const { glibcVersionRuntime } = process.report.getReport().header;
console.log(`node ${process.version} (${process.release.sourceUrl}), glibc ${glibcVersionRuntime}`);

async function modelClass(id) {
  const mod = await import(`@desert-ant-labs/${id}/native`);
  const cls = Object.values(mod).find((v) => typeof v?.load === "function");
  assert.ok(cls, `@desert-ant-labs/${id}/native exports no class with load()`);
  return cls;
}

for (const id of models) {
  const Model = await modelClass(id);
  if (noLibcurl) {
    await assert.rejects(Model.load({}), /libcurl is required/, id);
    console.log(`${id}: core and LiteRT linked, load() rejected for the missing libcurl`);
    continue;
  }
  assert.equal(id, "align", "only align runs a full load here");
  const align = await Model.load({});
  try {
    const tone = new Float32Array(3 * 16000);
    for (let i = 0; i < tone.length; i++) tone[i] = 0.3 * Math.sin((2 * Math.PI * 200 * i) / 16000);
    const words = [{ text: "hola", start: 0.4, end: 0.71 }, { text: "mundo", start: 0.8, end: 1.3 }];
    const out = await align.refine(tone, 16000, words, { language: "es" });
    assert.equal(out.length, 2);
    assert.ok(out.some((w) => w.refined), "no word was refined: the native core ran nothing");
    console.log(`align downloaded and refined: ${JSON.stringify(out)}`);
  } finally {
    align.dispose();
  }
}
