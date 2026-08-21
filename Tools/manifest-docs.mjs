// Renders manifest.json into the surfaces that publish it. One module so the
// GitHub README table and the Hugging Face org card cannot disagree: they are
// the same function over the same file.

import { readFileSync } from "node:fs";

export const MARKERS = { start: "<!-- models:start -->", end: "<!-- models:end -->" };

export function manifest(root = ".") {
  return JSON.parse(readFileSync(`${root}/manifest.json`, "utf8"));
}

/// Lifecycle and visibility are separate facts; readers want one word.
function status(model) {
  if (model.lifecycle === "beta" && model.visibility === "internal") return "Closed beta";
  return model.lifecycle[0].toUpperCase() + model.lifecycle.slice(1);
}

/// Package coordinates for every SDK that ships, in Swift/Kotlin/JS order.
function sdks(model) {
  const live = ["swift", "kotlin", "js"]
    .map((sdk) => model.sdks[sdk])
    .filter((sdk) => sdk?.status === "live" && sdk.package)
    .map((sdk) => `\`${sdk.package}\``);
  return live.length ? live.join(" · ") : "—";
}

/// A commit pin is 40 characters of noise in a table cell; a tag is not.
function short(revision) {
  if (!revision) return "main";
  const isCommit = revision.length === 40 && /^[0-9a-f]+$/.test(revision);
  return isCommit ? revision.slice(0, 7) : revision;
}

/// A gated repo has nothing a reader can open, so it gets no link at all.
function weights(model, { linkInternal = false } = {}) {
  const { source, url, revision } = model.weights;
  if (model.visibility === "internal" && !linkInternal) return "—";
  if (source === "bundled") return revision ? `Bundled · [${revision}](${url})` : "Bundled";
  if (source === "none" || !url) return "—";
  return `[${short(revision)}](${url})`;
}

/// The table both surfaces publish. Rows follow the manifest's A-Z order.
export function renderTable(models) {
  const rows = models.map(
    (m) => `| **${m.name}** | ${m.summary} | ${sdks(m)} | ${weights(m)} | ${status(m)} |`
  );
  return [
    "| Model | What it does | SDKs | Weights | Status |",
    "| --- | --- | --- | --- | --- |",
    ...rows,
  ].join("\n");
}

/// Replace the marked block in `text`, leaving every hand-written line alone.
export function replaceBlock(text, body) {
  const start = text.indexOf(MARKERS.start);
  const end = text.indexOf(MARKERS.end);
  if (start === -1 || end === -1) throw new Error(`missing ${MARKERS.start} / ${MARKERS.end} markers`);
  return text.slice(0, start) + `${MARKERS.start}\n${body}\n` + text.slice(end);
}
