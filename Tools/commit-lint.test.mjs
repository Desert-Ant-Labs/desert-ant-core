import assert from "node:assert/strict";
import test from "node:test";
import { lint } from "./commit-lint.mjs";

// Code points, so this file passes the dash rule it tests.
const EM = String.fromCharCode(0x2014);
const EN = String.fromCharCode(0x2013);

const ok = (msg, opts) => assert.deepEqual(lint(msg, opts).errors, [], msg);
const bad = (msg, pattern, opts) => {
  const { errors } = lint(msg, opts);
  assert.ok(errors.length > 0, `expected an error for: ${msg}`);
  if (pattern) assert.match(errors.join("\n"), pattern);
};

test("accepts the usual shapes", () => {
  ok("feat: add a thing");
  ok("fix(android): trap when the host returns no NFC result");
  ok("build(android)!: raise minSdk to 26");
  ok("docs(toxic): the comparison table");
  ok("feat(a/b c): free-form scopes pass");
  ok("Feat: the type may be capitalized");
  ok("FIX(Android): or shouted");
});

test("is lax about casing, punctuation, body, and footers", () => {
  ok("fix: Trap when the host returns nothing.");
  ok("fix: API 37 and NFC are acronyms");
  ok("feat: x\n\nAny body at all, even one very long line that goes well past seventy-two characters without wrapping.\n\nCloses #12");
});

test("rejects headers that are not conventional", () => {
  bad("Update to API 37", /header is/);
  bad("Toxic: the page copy", /unknown type|header is/);
  bad("wip: half done", /unknown type "wip"/);
  bad("feat:no space", /one space/);
  bad("feat: ", /one space/);
  bad("feat(): empty scope", /header is/);
});

test("caps the header at 100 characters and only warns past 72", () => {
  ok(`feat: ${"x".repeat(60)}`);
  assert.equal(lint(`feat: ${"x".repeat(70)}`).warnings.length, 1);
  bad(`feat: ${"x".repeat(100)}`, /characters/);
});

test("rejects em and en dashes in the header and the body", () => {
  bad(`feat: add a thing ${EM} quickly`, /dashes/);
  bad(`feat: add a thing\n\nBody with an en dash ${EN} here`, /dashes/);
  ok("feat: add a hyphen-ated thing");
});

test("a PR title is judged on its first line only", () => {
  bad("Update to API 37", /header is/, { headerOnly: true });
  ok(`feat: fine\n\nbody ${EM} not checked for a title`, { headerOnly: true });
});

test("skips merges, reverts, autosquash commits, and empty messages", () => {
  for (const msg of ['Merge branch "main"', 'Revert "feat: x"', "fixup! feat: x", "squash! feat: x", "amend! feat: x", ""]) {
    assert.equal(lint(msg).skipped, true, msg);
  }
  assert.equal(lint("# only a comment", { editor: true }).skipped, true);
});

test("the hook ignores git's comment lines and the verbose diff", () => {
  ok(`feat: add a thing\n\n# Please enter the commit message\n# ${EM} a comment git strips`, { editor: true });
  ok(`fix: x\n# ------------------------ >8 ------------------------\n+ an added ${EM} line in the diff`, { editor: true });
});

test("stored commits and titles are judged as written, so a # line is real text", () => {
  bad(`feat: x\n\n# Heading ${EM} with a dash`, /dashes/);
  bad("# not a conventional title", /header is/);
  bad("# not a conventional title", /header is/, { headerOnly: true });
});
