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
    // Two links, because they answer different questions. The SDK page says how
    // to install and call it; the card says what the model is. A single "docs"
    // link had to pick one, and picked the one the org card is not about.
    ...shipping.map(
      (m) =>
        `| **${m.name}** | ${m.summary} | ${platforms(m, "short")} | ` +
        `[SDK](${docsURL(m, org)}) [Model](${m.weights.url}) |`
    ),
  ];
  if (!preview.length) return main.join("\n");

  const rest = [
    "| Model | What it does | Docs |",
    "| --- | --- | --- |",
    ...preview.map((m) => `| **${m.name}** | ${m.summary} | [Model](${m.weights.url}) |`),
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

/// The card is TWO halves and only the first is ours. Identity comes from the
/// manifest so a card cannot drift from the registry; everything below the
/// markers is the model's own documentation, written on the Hub by whoever has
/// the numbers, and is carried across untouched.
///
/// It did not used to be. This returned front matter plus `renderCardBody` and
/// nothing else, so every sync replaced each card whole. Two runs, 2026-08-21
/// and 2026-08-24, took clear from 168 lines to 29, redact from 194 to 52 and
/// emo from 115 to 47, and redact's benchmark section went with them. The org
/// card survived both because it alone went through `replaceMarked`.
///
/// AN UNMARKED CARD IS REFUSED, NOT ADOPTED. Guessing where the generated half
/// ends means either duplicating the heading or deleting an intro that carries
/// figures the manifest does not hold, and redact's two deployable sizes live
/// exactly there. This incident was an automated rewrite being too clever, so
/// the migration is a person adding the markers once, and until they do the
/// card is left alone.
export function renderCard(existing, model, org, version) {
  const { frontMatter, body } = splitCard(existing);
  if (!body.includes(CARD_MARKERS.start)) throw new UnmarkedCard(model.id);
  const front = mergeFrontMatter(frontMatter, model);
  let next = replaceMarked(body, renderCardBody(model, org), CARD_MARKERS);
  if (next.includes(CARD_INSTALL_MARKERS.start)) {
    next = replaceMarked(next, renderCardInstall(model, org, version), CARD_INSTALL_MARKERS);
  }
  if (next.includes(CARD_FOOTER_MARKERS.start)) {
    next = replaceMarked(next, renderCardFooter(model, org), CARD_FOOTER_MARKERS);
  }
  return `---\n${front}\n---\n\n${next.trimStart()}`;
}

/// Distinguishable from a network or token failure, because it is neither: the
/// card is fine and the sync has no mandate over it yet.
export class UnmarkedCard extends Error {
  constructor(id) {
    super(`${id}: no card-header block, so the sync cannot tell which half is generated`);
    this.name = "UnmarkedCard";
    this.id = id;
  }
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

/// The Hub's markers are NOT the model page's. A card is read and edited on a
/// site where every block is about the model, so `model:start` names nothing and
/// warns nobody. These name the block and say what to do instead, in the marker
/// itself rather than in a comment above it that a careless edit would drop.
export const CARD_MARKERS = {
  start: "<!-- card-header:start (generated from manifest.json, edit below this block) -->",
  end: "<!-- card-header:end -->",
};

/// Two more generated blocks, each INDEPENDENT of the others. A card opts into
/// one by having its markers; a card without them keeps whatever it has. Making
/// them all-or-nothing would break every card the day the feature landed.
export const CARD_INSTALL_MARKERS = {
  start: "<!-- card-install:start (generated from manifest.json, edit below this block) -->",
  end: "<!-- card-install:end -->",
};
export const CARD_FOOTER_MARKERS = {
  start: "<!-- card-footer:start (generated from manifest.json, edit above this block) -->",
  end: "<!-- card-footer:end -->",
};

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

/// The card's install half. Same source as the model page's, so a release bump
/// rewrites both, but with ABSOLUTE links: `install()` emits `../../README.md`,
/// which resolves inside this repo and 404s on huggingface.co.
export function renderCardInstall(model, org, version) {
  const facts = [["Platforms", platforms(model)]];
  if (model.languages?.count) facts.push(["Languages", String(model.languages.count)]);
  facts.push(["Weights", `[${short(model.weights.revision)}](${model.weights.url})`]);
  const lines = [
    "| | |",
    "| --- | --- |",
    ...facts.map(([k, v]) => `| **${k}** | ${v} |`),
    "",
    "## Install",
    "",
    ...install(model, version),
  ];
  return lines
    .join("\n")
    .replaceAll("../../README.md", `${org.github}/desert-ant-core/blob/main/README.md`)
    .trimEnd();
}

/// The boilerplate every card ends with and no two cards agreed on. Measured
/// 2026-08-28 across eight cards: four different shapes. Three had no copyright
/// line, four had no notices link, one had no licensing address and no License
/// section at all.
///
/// `Built on` and `Citation` are deliberately NOT here. Those are per-model, and
/// generating them would be this same mistake in a smaller box.
export function renderCardFooter(model, org) {
  const summary = model.summary.replace(/\.$/, "");
  return [
    "## License",
    "",
    `[${org.name} Source-Available License](https://license.desertant.com/1.0). Free for most`,
    "apps, and a commercial license is required at scale. Full terms are at the link.",
    "Licensing: <licensing@desertant.com>.",
    "",
    "See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).",
    "",
    // Three cards of fourteen had one, and the other eleven left a reader with
    // nothing to paste. Every field here is already in the manifest, so the
    // block is uniform and cannot go stale against the repo it points at.
    "## Citation",
    "",
    "```bibtex",
    `@software{${model.id}_2026,`,
    `  title  = {${model.name}: ${summary}},`,
    `  author = {${org.name}},`,
    "  year   = {2026},",
    `  url    = {${model.weights.url}},`,
    "}",
    "```",
    "",
    "---",
    "",
    `© 2026 ${org.name} · <${org.site}>`,
  ].join("\n");
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
