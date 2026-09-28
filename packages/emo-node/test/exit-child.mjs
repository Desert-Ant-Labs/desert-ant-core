// Spawned by exit-with-send.test.mjs; EXIT_CASE picks the shape, and the script ends with a usage send pending.
const mode = process.env.EXIT_CASE ?? "dispose";
// The test setup forces the closed port; the parent's capture server is set here, after it.
process.env.DAL_INGEST_ENDPOINT = process.env.CAPTURE_ENDPOINT;
// An app listener registered first that exits at once must not skip the usage wait.
if (mode === "early-exit-listener") process.on("exit", () => process.exit(0));
const { Emo } = await import("../node.js");
const emo = await Emo.load();
await emo.suggestions("Pay my bills", { limit: 1 });
if (mode === "two-libraries") {
  const { Shapes } = await import("../../shapes-node/node.js");
  const shapes = await Shapes.load();
  const circle = Array.from({ length: 64 }, (_, i) => ({ x: 100 + 80 * Math.cos((i / 64) * 2 * Math.PI), y: 100 + 80 * Math.sin((i / 64) * 2 * Math.PI) }));
  await shapes.recognize(circle);
  shapes.dispose();
}
if (mode !== "no-dispose") emo.dispose();
// The parent measures the exit delay from here.
process.stderr.write(`body-done ${Date.now()}\n`);
