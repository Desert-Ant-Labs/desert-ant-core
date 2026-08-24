// Renders manifest.json into the surfaces that publish it. One module so the
// GitHub README table and the Hugging Face org card cannot disagree: they are
// the same function over the same file.

import { existsSync, readFileSync } from "node:fs";

export const MARKERS = { start: "<!-- models:start -->", end: "<!-- models:end -->" };

export function manifest(root = ".") {
  return JSON.parse(readFileSync(`${root}/manifest.json`, "utf8"));
}

/// A model ships when at least one SDK is live. That one fact drives the split:
/// the main table is what a reader can install today, everything else is the
/// closed-beta list underneath it.
export function ships(model) {
  return SDKS.some((sdk) => model.sdks[sdk]?.status === "live");
}

const SDKS = ["swift", "kotlin", "js"];

/// A commit pin is 40 characters of noise in a table cell; a tag is not.
function short(revision) {
  if (!revision) return "main";
  const isCommit = revision.length === 40 && /^[0-9a-f]+$/.test(revision);
  return isCommit ? revision.slice(0, 7) : revision;
}

/// The per-model page, which is the only documentation link a table carries.
/// Absolute because two of the three surfaces that publish this table are not
/// in this repo, so a relative path would resolve against the wrong root.
export function docsURL(model, org) {
  return `${org.github}/desert-ant-core/blob/main/${docsPath(model)}`;
}

export function docsPath(model) {
  return `docs/models/${model.id}.md`;
}

/// The tables every surface publishes: what you can install, then what is
/// coming. Rows follow the manifest's A-Z order. One marked block holds both,
/// so a surface adopting this needs no extra markers.
export function renderTable(models, org) {
  const shipping = models.filter(ships);
  const preview = models.filter((m) => !ships(m));

  const main = [
    "| Model | What it does | Platform | Docs |",
    "| --- | --- | --- | --- |",
    ...shipping.map(
      (m) => `| **${m.name}** | ${m.summary} | ${platforms(m, "short")} | [docs](${docsURL(m, org)}) |`
    ),
  ];
  if (!preview.length) return main.join("\n");

  const rest = [
    "| Model | What it does |",
    "| --- | --- |",
    ...preview.map((m) => `| **${m.name}** | ${m.summary} |`),
  ];
  return [
    ...main,
    "",
    "### In closed beta",
    "",
    "Weights exist and the models work, but no SDK ships them yet, so there is",
    "nothing to install today. Ask us if you want early access.",
    "",
    ...rest,
  ].join("\n");
}

/// The Hub card body: what the model is, and where the real docs are. A reader
/// who lands here wants the SDK, so a shipping model links straight at its page
/// of install lines and examples rather than at a repo root to go hunting in.
export function renderCardBody(model, org) {
  const links = ships(model)
    ? [`- **SDKs, install and examples:** ${docsURL(model, org)}`]
    : [`- **GitHub:** ${model.home ? `${org.github}/${model.home}` : org.github}`];
  if (model.demo?.page) links.push(`- **Website:** ${model.demo.page}`);
  return [`# ${model.name}`, "", model.tagline, "", model.summary, "", ...links, ""].join("\n");
}

/// Front matter is HF's search index, not prose, so it survives the rewrite —
/// but every field in it is the manifest's, so a card cannot drift from the
/// registry. Unknown keys still round-trip untouched.
export function mergeFrontMatter(existing, model) {
  const owned = { license: "other" };
  owned.license_name = model.weights.license;
  owned.license_link = "https://license.desertant.com/1.0";
  // `undefined` drops the key: a model the manifest says has no languages must
  // not keep one from the card it is replacing (clear's claimed `en`, for a
  // denoiser).
  const codes = model.languages?.codes;
  owned.language = codes ?? (model.languages ? ["multilingual"] : undefined);
  owned.tags = model.hub.tags;
  if (model.hub.pipelineTag) owned.pipeline_tag = model.hub.pipelineTag;
  if (model.hub.libraryName) owned.library_name = model.hub.libraryName;

  const blocks = parseBlocks(existing);
  const rendered = [];
  const seen = new Set();
  for (const [key, lines] of blocks) {
    if (key in owned) {
      if (owned[key] !== undefined) rendered.push(emit(key, owned[key]));
      seen.add(key);
    } else {
      rendered.push(lines.join("\n"));
    }
  }
  for (const [key, value] of Object.entries(owned)) {
    if (!seen.has(key) && value !== undefined) rendered.push(emit(key, value));
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

/// Put markers around a table that predates them, so a hand-written page can be
/// adopted without editing it by hand first. `header` is the start of its header
/// row; the table runs to the next blank line.
export function insertMarkers(text, header) {
  if (text.includes(MARKERS.start)) return text;
  const table = new RegExp(`^\\| ${header} \\|[\\s\\S]*?(?=\\n\\n)`, "m");
  if (!table.test(text)) throw new Error(`no table starting "| ${header} |" to replace`);
  return text.replace(table, `${MARKERS.start}\n${MARKERS.end}`);
}

/// Replace the marked block in `text`, leaving every hand-written line alone.
export function replaceBlock(text, body) {
  const start = text.indexOf(MARKERS.start);
  const end = text.indexOf(MARKERS.end);
  if (start === -1 || end === -1) throw new Error(`missing ${MARKERS.start} / ${MARKERS.end} markers`);
  return text.slice(0, start) + `${MARKERS.start}\n${body}\n` + text.slice(end);
}

export const MODEL_MARKERS = { start: "<!-- model:start -->", end: "<!-- model:end -->" };

/// The page header has room to name the Apple OSes; a table cell does not.
const PLATFORM_NAMES = {
  apple: { short: "Apple", long: "iOS, macOS, tvOS, visionOS" },
  android: { short: "Android", long: "Android" },
  linux: { short: "Linux", long: "Linux" },
  windows: { short: "Windows", long: "Windows" },
  web: { short: "Web", long: "Browser" },
  node: { short: "Node", long: "Node" },
};

/// Rendered in this order rather than the order the SDKs happen to declare
/// them, so every row reads the same way down the column.
const PLATFORM_ORDER = ["apple", "android", "linux", "windows", "web", "node"];

/// Every platform any live SDK claims, deduplicated and canonically ordered.
function platformIDs(model) {
  const seen = new Set();
  for (const sdk of SDKS) {
    const decl = model.sdks[sdk];
    if (decl?.status === "live") for (const p of decl.platforms ?? []) seen.add(p);
  }
  return PLATFORM_ORDER.filter((p) => seen.has(p));
}

function platforms(model, form = "long") {
  return platformIDs(model)
    .map((p) => PLATFORM_NAMES[p]?.[form] ?? p)
    .join(form === "short" ? " · " : ", ");
}

/// The install snippet per SDK. Versions come from the manifest so a release
/// bump rewrites all ten pages instead of leaving stale coordinates behind.
function install(model, version) {
  const out = [];
  const { swift, kotlin, js } = model.sdks;

  if (swift?.status === "live") {
    // MLX is behind a package trait, and a build that omits it compiles against
    // a stub with no public initializer, so the coordinate alone is not enough.
    const mlx = model.runtime.includes("mlx");
    out.push(
      "**Swift** ([requirements](../../README.md#swift))",
      "",
      "```swift",
      mlx
        ? `.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "${version}",
        traits: ["MLX"])`
        : `.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "${version}")`,
      "```",
      "",
      `Then add the \`${swift.package}\` product to your target.` +
        (mlx ? " The `MLX` trait is required: without it the module compiles as a stub." : ""),
      ""
    );
  }
  if (kotlin?.status === "live") {
    out.push(
      "**Kotlin** ([requirements](../../README.md#android))",
      "",
      "```kotlin",
      `implementation("${kotlin.package}:${version}")`,
      "```",
      ""
    );
  }
  if (js?.status === "live") {
    // A pure-JavaScript model has no inference runtime to bring along, so it is
    // one install line rather than a browser/Node pair.
    const lines = model.runtime.includes("pure")
      ? [`npm i ${js.package}`]
      : [
          `npm i ${js.package} @litertjs/core   # browser`,
          `npm i ${js.package}                  # Node, prebuilt native core`,
        ];
    out.push(
      "**JavaScript** ([requirements](../../README.md#javascript-and-typescript))",
      "",
      "```bash",
      ...lines,
      "```",
      ""
    );
  }
  return out;
}

/// The generated half of a model page: identity, facts, and install lines. The
/// usage examples below it are hand-written, because an example is a judgement
/// about what a reader needs first and no manifest field holds that.
export function renderModelHeader(model, org, version) {
  const facts = [["Platforms", platforms(model)]];
  if (model.languages?.count) facts.push(["Languages", String(model.languages.count)]);
  facts.push([
    "Weights",
    model.weights.source === "bundled"
      ? `Bundled with the SDK ([${short(model.weights.revision)}](${model.weights.url}))`
      : `[${short(model.weights.revision)}](${model.weights.url})`,
  ]);
  if (model.demo?.page) facts.push(["Demo", model.demo.page]);

  return [
    `# ${model.name}`,
    "",
    model.tagline,
    "",
    model.summary,
    "",
    "| | |",
    "| --- | --- |",
    ...facts.map(([k, v]) => `| **${k}** | ${v} |`),
    "",
    "## Install",
    "",
    ...install(model, version),
  ].join("\n").trimEnd();
}

/// Replace a marked block whichever markers it uses.
export function replaceMarked(text, body, markers = MARKERS) {
  const start = text.indexOf(markers.start);
  const end = text.indexOf(markers.end);
  if (start === -1 || end === -1) throw new Error(`missing ${markers.start} / ${markers.end} markers`);
  return text.slice(0, start) + `${markers.start}\n${body}\n` + text.slice(end);
}

/// Every generated documentation file, as path -> full new contents. Render and
/// check both go through this, so "what should be on disk" has one definition
/// and the two can never disagree about it.
export function renderAll(root = ".") {
  const { models, org, sdkVersion } = manifest(root);
  const out = {
    "README.md": replaceMarked(readFileSync(`${root}/README.md`, "utf8"), renderTable(models, org)),
  };
  for (const model of models.filter(ships)) {
    const path = docsPath(model);
    if (!existsSync(`${root}/${path}`)) {
      throw new Error(`${model.id} ships an SDK but ${path} does not exist`);
    }
    out[path] = replaceMarked(
      readFileSync(`${root}/${path}`, "utf8"),
      renderModelHeader(model, org, sdkVersion),
      MODEL_MARKERS
    );
  }
  return out;
}
