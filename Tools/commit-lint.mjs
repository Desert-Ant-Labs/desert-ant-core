#!/usr/bin/env node
// Conventional Commits check, deliberately lax. One validator behind the three
// places a message is judged: the commit-msg git hook, check:commit-format over a
// range of commits in CI, and the PR title (a squash merge puts it on main).
//
//   node Tools/commit-lint.mjs --file .git/COMMIT_EDITMSG   the hook
//   node Tools/commit-lint.mjs --title "feat(x): add y"     a PR title
//   node Tools/commit-lint.mjs --range origin/main..HEAD    every non-merge commit
//
// What it enforces: a header of `type(scope)?!?: subject` with a known type
// (any casing), a non-empty subject, a header of at most 100 characters, and no em or en
// dashes anywhere in the message (the house style in AGENTS.md). What it leaves
// alone on purpose: subject casing, a trailing period, the scope vocabulary, the
// body, the footers. Merge, revert, and fixup!/squash!/amend! commits are skipped.
//
// Exit 0 passes (warnings still print), 1 fails.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const TYPES = ["feat", "fix", "docs", "build", "ci", "test", "perf", "refactor", "chore", "style", "revert"];
const MAX_HEADER = 100;
const WARN_HEADER = 72;
const HEADER = new RegExp(`^(${TYPES.join("|")})(\\(([^()\\s][^()]*)\\))?(!)?: (\\S.*)$`, "i");
const SKIPPED = /^(Merge |Revert "|(fixup|squash|amend)! )/;
// En dash and em dash, spelled as code points so this file passes its own rule.
const DASH = new RegExp(`[${String.fromCharCode(0x2013, 0x2014)}]`);
// `git commit -v` appends the diff under this line; git strips it, a hook sees it.
const TEMPLATE = /^# Please enter the commit message/m;
const SCISSORS = /^# -+ >8 -+$/;

// The message as git would record it from the editor: no scissors section, no
// comment lines. Only the commit-msg hook sees text git has not cleaned yet; a
// stored commit or a PR title is judged as written, so a "#" line there is real.
export function clean(text) {
  const lines = [];
  for (const line of text.split(/\r?\n/)) {
    if (SCISSORS.test(line)) break;
    if (!line.startsWith("#")) lines.push(line);
  }
  return lines.join("\n").trim();
}

// message: the full text. headerOnly: judge just the first line (a PR title).
// editor: the text is a commit-msg hook file, so strip what git is about to strip.
export function lint(message, { headerOnly = false, editor = false } = {}) {
  const text = editor ? clean(message) : message.trim();
  const errors = [];
  const warnings = [];
  if (text === "") return { skipped: true, errors, warnings };
  const header = text.split("\n")[0];
  if (SKIPPED.test(header)) return { skipped: true, errors, warnings };

  if (!HEADER.test(header)) {
    const colon = header.indexOf(":");
    const type = colon > 0 ? header.slice(0, colon).replace(/\(.*$/, "").replace(/!$/, "") : "";
    if (colon > 0 && /^[a-z]+$/i.test(type) && !TYPES.includes(type.toLowerCase())) {
      errors.push(`unknown type "${type}"; use one of: ${TYPES.join(", ")}`);
    } else if (colon > 0 && !header.slice(colon).startsWith(": ")) {
      errors.push('the colon is followed by one space: "type(scope): subject"');
    } else {
      errors.push('the header is "type(scope): subject" (the scope is optional, and "!" before the colon marks a breaking change)');
    }
  }
  if (header.length > MAX_HEADER) {
    errors.push(`the header is ${header.length} characters; keep it under ${MAX_HEADER} and move detail to the body`);
  } else if (header.length > WARN_HEADER) {
    warnings.push(`the header is ${header.length} characters; 72 or fewer reads better in logs`);
  }
  const scanned = headerOnly ? header : text;
  const dashed = scanned.split("\n").filter((l) => DASH.test(l));
  if (dashed.length > 0) {
    errors.push(
      `em and en dashes are not allowed (AGENTS.md, House style); use a hyphen, comma, parentheses, or separate sentences. Found in: "${dashed[0].trim().slice(0, 80)}"`,
    );
  }
  return { skipped: false, errors, warnings, header };
}

const EXAMPLES = [
  "feat(android): normalize text to NFC through the host bridge",
  "fix: trap when the host returns no NFC result",
  "docs(toxic): add the comparison table to the card",
  "build(android)!: raise minSdk to 26",
];

function report(label, result) {
  const out = [];
  for (const w of result.warnings) out.push(`  warning: ${w}`);
  if (result.errors.length > 0) {
    out.push(`error: ${label} does not follow the commit format (Conventional Commits, lax):`);
    for (const e of result.errors) out.push(`  - ${e}`);
    out.push(`  types: ${TYPES.join(", ")} (any casing)`);
    out.push("  examples:");
    for (const e of EXAMPLES) out.push(`    ${e}`);
    out.push("  Subject casing, a trailing period, and the scope are up to you.");
  }
  if (out.length > 0) console.error(out.join("\n"));
}

function git(args) {
  return execFileSync("git", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function main(argv) {
  const [flag, value] = argv;
  if (!value || !["--file", "--title", "--range"].includes(flag)) {
    console.error("usage: commit-lint.mjs --file <path> | --title <text> | --range <a..b>");
    return 2;
  }
  if (flag === "--file") {
    const raw = readFileSync(value, "utf8");
    // `git commit -m` and `-F` keep "#" lines as written; only the editor template
    // is stripped, so strip only when git's template text is present.
    const result = lint(raw, { editor: TEMPLATE.test(raw) });
    report("this commit message", result);
    return result.errors.length > 0 ? 1 : 0;
  }
  if (flag === "--title") {
    const result = lint(value, { headerOnly: true });
    report("this pull request title", result);
    return result.errors.length > 0 ? 1 : 0;
  }
  let bad = 0;
  const shas = git(["rev-list", "--no-merges", value]).split("\n").filter(Boolean);
  for (const sha of shas) {
    const result = lint(git(["log", "-1", "--format=%B", sha]));
    if (result.errors.length === 0) continue;
    bad++;
    report(`commit ${git(["log", "-1", "--format=%h %s", sha]).trim()}`, result);
  }
  if (bad > 0) {
    console.error(`\nerror: ${bad} of ${shas.length} commits in ${value} need a reword (git rebase -i, or git commit --amend for the last one)`);
    return 1;
  }
  console.log(`${shas.length} commits in ${value} follow the commit format`);
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exit(main(process.argv.slice(2)));
