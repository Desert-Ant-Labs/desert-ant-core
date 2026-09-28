// Spawned by dispose-usage.test.mjs: runs one SCENARIO against an in-process server and prints a JSON result.
import http from "node:http";
import { randomUUID } from "node:crypto";

const scenario = process.env.SCENARIO;
const stall = scenario === "dispose-during-flush";
const posts = [];
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    posts.push(JSON.parse(body));
    if (!stall) res.writeHead(202).end();
  });
});
// A short keep-alive, so the native client's idle connection does not hold the process open for Node's 5 s default.
server.keepAliveTimeout = 100;
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
server.unref();
// Set before the native core starts: it reads the environment when a model builds its usage client.
process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${server.address().port}/api/v1/ingest`;
process.env.DAL_APP_ID = `${process.env.DAL_APP_ID}.dispose.${randomUUID()}`;
const { Emo } = await import("../node.js");
const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// A dispose finishes in the background, so wait for the expected posts (up to 5 s), then a little longer for any extra one.
async function postsReach(count) {
  for (let waited = 0; posts.length < count && waited < 5000; waited += 50) await settle(50);
  await settle(300);
}
const run = (emo) => emo.suggestions("Pay my bills", { limit: 1 });
const result = {};

if (scenario === "window") {
  for (let cycle = 0; cycle < 2; cycle++) {
    const emo = await Emo.load();
    await run(emo);
    emo.dispose();
    await postsReach(1);
    result[`afterCycle${cycle}`] = posts.map((p) => p.events.map((e) => e.callCount ?? 0));
  }
} else if (scenario === "isolation") {
  const a = await Emo.load();
  const b = await Emo.load();
  await run(a);
  await run(b);
  a.dispose();
  await postsReach(1);
  result.afterDisposeA = posts.length;
  b.dispose();
  await postsReach(1);
  result.afterDisposeB = posts.length;
} else if (scenario === "dispose-during-flush") {
  const emo = await Emo.load();
  await run(emo);
  void emo.flushTelemetry();
  await settle(300);
  await run(emo);
  const started = performance.now();
  emo.dispose();
  result.disposeMs = performance.now() - started;
}
if (scenario === "saturated") {
  // More concurrent runs than cores, so every Swift pool thread is busy while one handle is disposed.
  const { availableParallelism } = await import("node:os");
  const victim = await Emo.load();
  await run(victim);
  const busy = await Promise.all(Array.from({ length: availableParallelism() + 2 }, () => Emo.load()));
  let running = true;
  const loops = busy.map(async (emo) => {
    while (running) await run(emo);
  });
  await settle(300);
  const started = performance.now();
  victim.dispose();
  result.disposeMs = performance.now() - started;
  running = false;
  await Promise.all(loops);
  for (const emo of busy) emo.dispose();
}
// Marked, since the native runtime may log to stdout too.
process.stdout.write(`\nRESULT ${JSON.stringify(result)}\n`);
