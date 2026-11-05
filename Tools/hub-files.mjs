// Writes the files mise run hub:publish would put in each named model's Hugging
// Face repo to <dir>/<model>/, rendered from this checkout. private/lib.sh runs it
// at the ref whose weights it publishes, so the tag's commit carries that card.
// Usage: node Tools/hub-files.mjs <dir> <model>...
import { mkdirSync, writeFileSync } from "node:fs";
import { manifest, renderHubFiles } from "./manifest-docs.mjs";

const [dir, ...ids] = process.argv.slice(2);
const { models } = manifest();
for (const id of ids) {
  const model = models.find((m) => m.id === id);
  if (!model) throw new Error(`no model named ${id} in manifest.json`);
  const files = renderHubFiles(model);
  mkdirSync(`${dir}/${id}`, { recursive: true });
  for (const [path, text] of Object.entries(files)) writeFileSync(`${dir}/${id}/${path}`, text);
}
