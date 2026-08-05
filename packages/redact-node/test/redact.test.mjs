// The redact-node test suite. Runs server-side in Node against the native core
// (the `@desert-ant-labs/redact/native` entry, i.e. node.js). No model is
// committed, so the suite downloads the pinned revision into a directory under
// the package on the first run and reuses it offline afterward. The native core
// picks each OS's runtime and artifact itself: Core ML (.mlmodelc) on macOS,
// LiteRT (.tflite) on Linux. The default universal WebAssembly + LiteRT.js entry
// is exercised by the headless-Chromium example.
import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Redact } from "../node.js";
// From redact.js, not node.js: pure data, so these assert without a native core.
import { DEFAULT_LABELS, ALL_LABELS } from "../redact.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.join(here, ".model-cache");

let redact;
let loadError;
try {
  redact = await Redact.load({ directory });
} catch (e) {
  loadError = e;
}
const modelOpts = redact ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 100)}` };

test("redaction masks names, email, IBAN", modelOpts, async () => {
  const r = await redact.redaction("Email Anna Kovács at anna@example.hu, IBAN DE89370400440532013000.");
  assert.match(r.redactedText, /\[GIVEN_NAME_1\]/);
  assert.match(r.redactedText, /\[EMAIL_1\]/);
  assert.match(r.redactedText, /\[BANK_ACCOUNT_1\]/);
  assert.equal(r.items.find((i) => i.label === "EMAIL")?.original, "anna@example.hu");
});

test("addresses, VAT, IMEI redacted", modelOpts, async () => {
  const r = await redact.redaction("Ship to 123 Main Street, Apt 4B. VAT DE129273398, IMEI 490154203237518.");
  const got = new Set(r.items.map((i) => i.label));
  for (const l of ["BUILDING_NUMBER", "STREET_NAME", "SECONDARY_ADDRESS", "TAX_ID", "IMEI"]) {
    assert.ok(got.has(l), `expected ${l}`);
  }
});

test("restore round-trips exactly", modelOpts, async () => {
  const text = "Call Dr. Alice Grant on +49 30 1234567.";
  const r = await redact.redaction(text);
  assert.equal(r.restore(r.redactedText), text);
});

test("label filter", modelOpts, async () => {
  const r = await redact.redaction("Anna at anna@x.com, IBAN DE89370400440532013000.", { labels: ["EMAIL"] });
  assert.deepEqual(new Set(r.items.map((i) => i.label)), new Set(["EMAIL"]));
});

test("ORG is excluded from the default label set", () => {
  assert.ok(ALL_LABELS.includes("ORG"), "ORG must be a known label");
  assert.ok(!DEFAULT_LABELS.includes("ORG"), "ORG must NOT be redacted by default");
  assert.equal(DEFAULT_LABELS.length, ALL_LABELS.length - 1);
  for (const label of ALL_LABELS) {
    if (label !== "ORG") assert.ok(DEFAULT_LABELS.includes(label), `${label} should be on by default`);
  }
});

test("label sets are frozen so callers cannot mutate the default", () => {
  assert.ok(Object.isFrozen(DEFAULT_LABELS));
  assert.ok(Object.isFrozen(ALL_LABELS));
});

test("company names survive by default and can be opted into", modelOpts, async () => {
  const text = "We use Silverfin for invoicing.";
  const plain = await redact.redaction(text);
  assert.equal(plain.redactedText, text, "ORG must not be redacted by default");

  const withOrg = await redact.redaction(text, { labels: [...DEFAULT_LABELS, "ORG"] });
  assert.ok(withOrg.items.some((i) => i.label === "ORG"), "opting in must redact ORG");
});
