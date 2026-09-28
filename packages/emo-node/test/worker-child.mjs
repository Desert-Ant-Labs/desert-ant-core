// Run as a worker thread by worker-exit.test.mjs: load, run, dispose, then end normally.
import { parentPort } from "node:worker_threads";

const { Emo } = await import("../node.js");
const emo = await Emo.load();
await emo.suggestions("Pay my bills", { limit: 1 });
emo.dispose();
parentPort.postMessage("done");
