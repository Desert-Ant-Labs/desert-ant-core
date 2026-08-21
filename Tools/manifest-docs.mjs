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

/// Where a model's canonical docs live. Models with no repo of their own point
/// at the org, which is the honest answer rather than a link to nothing.
function github(model, org) {
  return model.home ? `${org.github}/${model.home}` : org.github;
}

/// The Hub card body: what the model is, and where the real docs are. Anything
/// longer belongs on GitHub, which this links to.
export function renderCardBody(model, org) {
  const links = [`- **SDKs and documentation:** ${github(model, org)}`];
  if (model.demo?.page) links.push(`- **Website:** ${model.demo.page}`);
  return [`# ${model.name}`, "", model.tagline, "", model.summary, "", ...links, ""].join("\n");
}

/// Front matter is HF's search index, not prose, so it survives the rewrite.
/// Only the fields the manifest is authoritative for are replaced; `tags`,
/// `pipeline_tag` and `library_name` are curated on the Hub and kept verbatim.
export function mergeFrontMatter(existing, model) {
  const owned = { license: "other" };
  owned.license_name = model.weights.license;
  owned.license_link = "https://license.desertant.com/1.0";
  const codes = model.languages?.codes;
  if (codes) owned.language = codes;
  else if (model.languages) owned.language = ["multilingual"];

  const blocks = parseBlocks(existing);
  const rendered = [];
  const seen = new Set();
  for (const [key, lines] of blocks) {
    if (key in owned) {
      rendered.push(emit(key, owned[key]));
      seen.add(key);
    } else {
      rendered.push(lines.join("\n"));
    }
  }
  for (const [key, value] of Object.entries(owned)) {
    if (!seen.has(key)) rendered.push(emit(key, value));
  }
  return rendered.join("\n");
}

/// Front matter as [key, rawLines] pairs, so unknown keys round-trip untouched
/// rather than being reserialized by a parser this repo does not have.
function parseBlocks(text) {
  const blocks = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    if (/^[A-Za-z_][\w-]*:/.test(line)) blocks.push([line.slice(0, line.indexOf(":")), [line]]);
    else if (blocks.length) blocks[blocks.length - 1][1].push(line);
  }
  return blocks;
}

function emit(key, value) {
  return Array.isArray(value) ? [`${key}:`, ...value.map((v) => `- ${v}`)].join("\n") : `${key}: ${value}`;
}

/// A card's front matter and body, split on the `---` fences.
export function splitCard(text) {
  const match = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  return match ? { frontMatter: match[1], body: match[2] } : { frontMatter: "", body: text };
}

export function renderCard(existing, model, org) {
  const front = mergeFrontMatter(splitCard(existing).frontMatter, model);
  return `---\n${front}\n---\n\n${renderCardBody(model, org)}`;
}

/// Replace the marked block in `text`, leaving every hand-written line alone.
export function replaceBlock(text, body) {
  const start = text.indexOf(MARKERS.start);
  const end = text.indexOf(MARKERS.end);
  if (start === -1 || end === -1) throw new Error(`missing ${MARKERS.start} / ${MARKERS.end} markers`);
  return text.slice(0, start) + `${MARKERS.start}\n${body}\n` + text.slice(end);
}
