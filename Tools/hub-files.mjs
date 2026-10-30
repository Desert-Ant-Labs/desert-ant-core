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
