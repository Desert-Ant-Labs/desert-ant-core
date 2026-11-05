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
    // to install and call it; the card says what the model is.
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

/// The keys of a card's front matter that come from the manifest. A sidecar
/// may not set them, so the Hub's search index cannot drift from the registry.
export const OWNED_FRONT_MATTER = ["license", "license_name", "license_link", "language", "tags", "pipeline_tag", "library_name"];

/// Front matter is the Hub's search index, not prose. Every owned key is the
/// manifest's; the rest (model-index, base_model) comes from the model's
/// sidecar, `docs/models/<id>.hub.yml`, verbatim.
export function hubFrontMatter(model, license, sidecar = "") {
  const owned = { license: "other" };
  owned.license_name = model.weights.license;
  owned.license_link = license.url;
  // A model with no languages gets no `language` key at all: a denoiser must
  // not claim `en`.
  const codes = model.languages?.codes;
  owned.language = codes ?? (model.languages ? ["multilingual"] : undefined);
  owned.tags = model.hub.tags;
  if (model.hub.pipelineTag) owned.pipeline_tag = model.hub.pipelineTag;
  if (model.hub.libraryName) owned.library_name = model.hub.libraryName;

  const lines = Object.entries(owned)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => emit(key, value));
  // The sidecar's own comments explain the file to its editors, not to the Hub.
  const extra = sidecar.split("\n").filter((line) => !/^\s*#/.test(line)).join("\n").trim();
  return [...lines, ...(extra ? [extra] : [])].join("\n");
}

/// The top-level keys of a YAML block, without a YAML parser this repo does not
/// have: a key starts a line in column zero.
export function frontMatterKeys(text) {
  return text
    .split("\n")
    .filter((line) => /^[A-Za-z_][\w-]*:/.test(line))
    .map((line) => line.slice(0, line.indexOf(":")));
}

function emit(key, value) {
  return Array.isArray(value) ? [`${key}:`, ...value.map((v) => `- ${v}`)].join("\n") : `${key}: ${value}`;
}

export function sidecarPath(model) {
  return `docs/models/${model.id}.hub.yml`;
}

/// The Hub card is the model page. It gets the Hub's front matter, and its
/// relative links are rewritten, because they resolve inside this repo and 404
/// on huggingface.co: a sibling model page goes to its page on the website, any
/// other path to GitHub.
export function renderHubCard(model, page, org, license, sidecar = "") {
  const body = rewriteLinks(page.replace(/^<!-- model(-install|-footer)?:(start|end) -->\r?\n/gm, ""), org);
  return [
    "---",
    hubFrontMatter(model, license, sidecar),
    "---",
    "",
    `<!-- Generated from ${docsPath(model)} in ${org.github}/desert-ant-core. Edit that file: changes made here are overwritten. -->`,
    "",
    body.trimStart(),
  ].join("\n");
}

function rewriteLinks(markdown, org) {
  // Code is left alone: a Swift subscript followed by a call reads like a link.
  return markdown
    .split(/(^```[\s\S]*?^```)/m)
    .map((chunk, index) =>
      index % 2
        ? chunk
        : chunk.replace(/(\]\()([^)\s]+)(\))/g, (full, open, url, close) => {
            if (/^(https?:|mailto:|#)/.test(url)) return full;
            const [path, anchor] = url.split("#");
            const resolved = posixJoin("docs/models", path);
            const sibling = resolved.match(/^docs\/models\/([a-z0-9-]+)\.md$/);
            const target = sibling
              ? `${org.site}/docs/${sibling[1]}/`
              : `${org.github}/desert-ant-core/blob/main/${resolved}`;
            return `${open}${target}${anchor ? `#${anchor}` : ""}${close}`;
          })
    )
    .join("");
}

function posixJoin(dir, path) {
  const parts = dir.split("/");
  for (const part of path.split("/")) {
    if (part === "..") parts.pop();
    else if (part !== "." && part !== "") parts.push(part);
  }
  return parts.join("/");
}

/// The files a model's Hugging Face repo gets from this repo, path -> contents:
/// its card and its third-party notices. Shared by mise run hub:publish and the
/// weights scripts, which put both in the same commit as the weights, so a tag
/// holds its own card and notices.
export function renderHubFiles(model, root = ".") {
  if (!ships(model)) return {};
  const { org, license } = manifest(root);
  const sidecar = existsSync(`${root}/${sidecarPath(model)}`) ? readFileSync(`${root}/${sidecarPath(model)}`, "utf8") : "";
  return {
    "README.md": renderHubCard(model, readFileSync(`${root}/${docsPath(model)}`, "utf8"), org, license, sidecar),
    "THIRD_PARTY_NOTICES.md": renderModelNotices(model, root),
  };
}

/// Every relative link in a page that resolves to nothing in this repo. The
/// page is published on GitHub, the website and the Hub, so a broken relative
/// link is broken in three places.
export function brokenRelativeLinks(page, root = ".") {
  const broken = [];
  for (const chunk of page.split(/(^```[\s\S]*?^```)/m).filter((_, index) => index % 2 === 0)) {
    for (const [, url] of chunk.matchAll(/\]\(([^)\s]+)\)/g)) {
      if (/^(https?:|mailto:|#)/.test(url)) continue;
      if (!existsSync(`${root}/${posixJoin("docs/models", url.split("#")[0])}`)) broken.push(url);
    }
  }
  return broken;
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

/// The license and citation every page ends with. Generated so all of them say
/// the same thing; the website drops both sections, since it has its own.
export const MODEL_INSTALL_MARKERS = { start: "<!-- model-install:start -->", end: "<!-- model-install:end -->" };
export const MODEL_FOOTER_MARKERS = { start: "<!-- model-footer:start -->", end: "<!-- model-footer:end -->" };

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
    // Which runtime the install line brings along is the model's, not a
    // constant: a pure-JavaScript model brings none, an ONNX one brings
    // onnxruntime-web (and has no native core to fall back to in Node), and
    // everything else is LiteRT.js in the browser against a prebuilt native
    // core on the server. A model with no browser build is one line whatever
    // it runs on, because there is only one build to install.
    const web = js.platforms?.includes("web") ?? true;
    let lines;
    if (model.runtime.includes("pure") || !web) {
      lines = [`npm i ${js.package}`];
    } else if (model.runtime.includes("onnx")) {
      lines = [`npm i ${js.package} onnxruntime-web`];
    } else {
      lines = [
        `npm i ${js.package} @litertjs/core   # browser`,
        `npm i ${js.package}                  # Node, prebuilt native core`,
      ];
    }
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

/// The weights at the revision the SDK pins: the exact files it downloads.
function weightsTreeURL(model) {
  return `${model.weights.url}/tree/${model.weights.revision}`;
}

/// A model page's generated header: identity and facts. The opening that says
/// what the model is for comes next, hand-written, then the install block.
export function renderModelHeader(model, org) {
  const facts = [["Platforms", platforms(model)]];
  if (model.languages?.count) facts.push(["Languages", String(model.languages.count)]);
  facts.push([
    "Weights",
    model.weights.source === "bundled"
      ? `Bundled with the SDK ([${short(model.weights.revision)}](${weightsTreeURL(model)}))`
      : `[${short(model.weights.revision)}](${weightsTreeURL(model)})`,
  ]);
  if (model.demo?.page) facts.push(["Demo", model.demo.page]);
  // The one place a page states its lifecycle, so no sentence can be left
  // behind when the manifest moves on.
  if (model.lifecycle === "beta") facts.push(["Status", "Beta"]);

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
  ].join("\n");
}

/// The install lines for each live SDK, at `sdkVersion`, so a release bump
/// rewrites every page.
export function renderModelInstall(model, version) {
  return ["## Install", "", ...install(model, version)].join("\n").trimEnd();
}

export const LICENSE_MARKERS = { start: "<!-- license:start -->", end: "<!-- license:end -->" };

export function renderLicense(org, license, notices = []) {
  return [
    "## License",
    "",
    `[${org.name} Source-Available License](${license.url}). Free for most`,
    "apps, and a commercial license is required at scale. Full terms are at the link.",
    "Licensing: <licensing@desertant.com>.",
    ...notices.flatMap((line) => ["", line]),
  ].join("\n");
}

function weightsNotices(model) {
  return `Third-party notices for the weights: [\`THIRD_PARTY_NOTICES.md\`](${model.weights.url}/blob/main/THIRD_PARTY_NOTICES.md).`;
}

function sdkNotices(org) {
  return `Third-party notices for the SDK: [\`THIRD_PARTY_NOTICES.md\`](${org.github}/desert-ant-core/blob/main/THIRD_PARTY_NOTICES.md).`;
}

export function renderModelFooter(model, org, license) {
  const summary = model.summary.replace(/\.$/, "");
  return [
    renderLicense(org, license, [weightsNotices(model)]),
    "",
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

/// The kinds of third-party work a model's notices list, in the order they
/// render. Nothing else is attributed: evaluation data, models that only labeled
/// or generated training data, and training tools are left out by design.
export const NOTICE_KINDS = {
  model: "Models",
  data: "Training data",
  file: "Data in the published files",
};
/// The SDK's own third-party libraries, from the manifest's top-level
/// `notices`: what the packages link, bundle or depend on.
export const SDK_NOTICE_KIND = "library";
export const NOTICE_FIELDS = ["kind", "name", "by", "license", "source", "copyright", "note"];
export const NOTICES_MARKERS = { start: "<!-- notices:start -->", end: "<!-- notices:end -->" };

/// The licenses an entry names: one SPDX id, or several when parts of the work
/// carry different ones. Each has its full text in LICENSES/<id>.txt.
export function noticeLicenses(entry) {
  return [entry.license].flat();
}

function licenseText(id, root) {
  return readFileSync(`${root}/LICENSES/${id}.txt`, "utf8").trim();
}

/// How each license reads in a notice. A license text added to LICENSES/
/// needs a name here too; check:manifest fails without one.
export const LICENSE_NAMES = {
  "Apache-2.0": "Apache License 2.0",
  "CC-BY-2.0": "CC BY 2.0",
  "CC-BY-2.0-FR": "CC BY 2.0 France",
  "CC-BY-3.0": "CC BY 3.0",
  "CC-BY-4.0": "CC BY 4.0",
  "CC-BY-SA-4.0": "CC BY-SA 4.0",
  MIT: "MIT License",
  "ODC-By-1.0": "Open Data Commons Attribution License 1.0",
  "Unicode-DFS-2016": "Unicode License Agreement for Data Files and Software (2016)",
  "LicenseRef-hunspell-en": "English Hunspell dictionary license",
  "LicenseRef-hunspell-fa": "Persian Hunspell dictionary license",
  "LicenseRef-hunspell-lt": "Lithuanian Hunspell dictionary license",
  "LicenseRef-hunspell-nl": "Dutch Hunspell dictionary license",
  "LicenseRef-hunspell-ru": "Russian Hunspell dictionary license",
  "LicenseRef-hunspell-tr": "Turkish Hunspell dictionary license",
  "MPL-2.0": "Mozilla Public License 2.0",
  "Unicode-3.0": "Unicode License v3",
};

function licenseName(id) {
  const name = LICENSE_NAMES[id];
  if (!name) throw new Error(`${id} has no entry in LICENSE_NAMES in Tools/manifest-docs.mjs`);
  return name;
}

function renderNoticeEntry(entry, root) {
  const licenses = noticeLicenses(entry).map(licenseName).join(", ");
  const lines = [`- **${entry.name}**, ${entry.by}. ${licenses}.${entry.note ? ` ${entry.note}` : ""}`, `  ${entry.source}`];
  if (entry.copyright) lines.push(`  ${entry.copyright}`);
  return lines.join("\n");
}

/// One model's notices, grouped by kind: what its published files contain or
/// derive from, and the training data whose license asks for attribution.
function renderNoticeSections(model, root, level) {
  const notices = model.notices ?? [];
  const h = "#".repeat(level);
  if (!notices.length) {
    return [`${model.name}'s weights build on no third-party model, and none of its training data asks for attribution.`];
  }
  const out = [];
  for (const [kind, title] of Object.entries(NOTICE_KINDS)) {
    const entries = notices.filter((n) => n.kind === kind);
    if (!entries.length) continue;
    out.push(`${h} ${title}`, "", ...entries.map((n) => renderNoticeEntry(n, root)), "");
  }
  return out;
}

/// The full text of every license the given notices name, once each.
function renderLicenseTexts(notices, root, level) {
  const ids = [...new Set(notices.flatMap(noticeLicenses))].sort();
  if (!ids.length) return [];
  const h = "#".repeat(level);
  const out = [`${h} License texts`, ""];
  for (const id of ids) out.push(`${h}# ${licenseName(id)}`, "", "```text", licenseText(id, root), "```", "");
  return out;
}

/// THIRD_PARTY_NOTICES.md for a model's Hugging Face repo. Generated from the
/// model's `notices` in manifest.json, with the full text of each license.
export function renderModelNotices(model, root = ".") {
  return [
    `# Third-party notices: ${model.name}`,
    "",
    `${model.name}'s weights build on the work below. Each license applies to its own work, and the`,
    "Desert Ant Labs Source-Available License doesn't override it. Training data isn't redistributed here.",
    "",
    ...renderNoticeSections(model, root, 2),
    ...renderLicenseTexts(model.notices ?? [], root, 2),
  ].join("\n").trimEnd() + "\n";
}

/// The generated part of this repo's THIRD_PARTY_NOTICES.md: the SDK's
/// libraries, every shipping model's notices, then each license's text once.
export function renderRepoNotices(manifestData, root = ".") {
  const sdk = manifestData.notices ?? [];
  const shipping = manifestData.models.filter(ships);
  const out = ["## SDK libraries", "", ...sdk.map((n) => renderNoticeEntry(n, root)), "", "## Model weights", ""];
  for (const model of shipping) out.push(`### ${model.name}`, "", ...renderNoticeSections(model, root, 4));
  out.push(...renderLicenseTexts([...sdk, ...shipping.flatMap((m) => m.notices ?? [])], root, 2));
  return out.join("\n").trimEnd();
}

/// Replace a marked block whichever markers it uses.
export function replaceMarked(text, body, markers = MARKERS) {
  const start = text.indexOf(markers.start);
  const end = text.indexOf(markers.end);
  if (start === -1 || end === -1) throw new Error(`missing ${markers.start} / ${markers.end} markers`);
  // Splice with the host text's own line ending, never a bare newline. Git for
  // Windows checks this repo out CRLF (core.autocrlf defaults on there), and an
  // LF-only block spliced into a CRLF file makes check:docs call every page
  // stale on every run, which docs:render then cannot fix.
  const eol = text.includes("\r\n") ? "\r\n" : "\n";
  const block = `${markers.start}\n${body}\n`.replaceAll("\n", eol);
  return text.slice(0, start) + block + text.slice(end);
}

/// Every generated documentation file, as path -> full new contents. Render and
/// check both go through this, so "what should be on disk" has one definition
/// and the two can never disagree about it.
export function renderAll(root = ".") {
  const data = manifest(root);
  const { models, org, sdkVersion, license } = data;
  const out = {
    "README.md": replaceMarked(readFileSync(`${root}/README.md`, "utf8"), renderTable(models, org)),
    "THIRD_PARTY_NOTICES.md": replaceMarked(
      readFileSync(`${root}/THIRD_PARTY_NOTICES.md`, "utf8"),
      renderRepoNotices(data, root),
      NOTICES_MARKERS
    ),
  };
  for (const model of models.filter(ships)) {
    const path = docsPath(model);
    if (!existsSync(`${root}/${path}`)) {
      throw new Error(`${model.id} ships an SDK but ${path} does not exist`);
    }
    let page = readFileSync(`${root}/${path}`, "utf8");
    page = replaceMarked(page, renderModelHeader(model, org), MODEL_MARKERS);
    page = replaceMarked(page, renderModelInstall(model, sdkVersion), MODEL_INSTALL_MARKERS);
    out[path] = replaceMarked(page, renderModelFooter(model, org, license), MODEL_FOOTER_MARKERS);
    const npm = `packages/${model.id}-node/README.md`;
    if (existsSync(`${root}/${npm}`)) {
      out[npm] = replaceMarked(
        readFileSync(`${root}/${npm}`, "utf8"),
        renderLicense(org, license, [sdkNotices(org), weightsNotices(model)]),
        LICENSE_MARKERS
      );
    }
  }
  out["js/README.md"] = replaceMarked(readFileSync(`${root}/js/README.md`, "utf8"), renderLicense(org, license, [sdkNotices(org)]), LICENSE_MARKERS);
  return out;
}
