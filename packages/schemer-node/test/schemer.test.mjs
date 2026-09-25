// The schemer-node test suite. Runs server-side in Node against the native
// core (the `@desert-ant-labs/schemer/native` entry, i.e. node.js). The default
// browser entry is exercised by browser-case.js in headless Chromium.
//
// Expected values are the reference goldens the Swift and Kotlin suites check
// (Tests/SchemerTests/Resources/schemer_golden.json), so the three SDKs are held
// to the same answers: Core ML's on macOS, LiteRT's on Linux. The model is
// adopted from SCHEMER_MODEL_DIR or test/fixtures/model when present
// (hermetic, and how an unpublished revision is tested), else downloaded from
// the Hub at the pinned revision.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { FfiReader, FfiWriter } from "@desert-ant-labs/core";
import {
  MAX_LABEL_VALUES, TRUNCATED, decodeExtraction, encodeInput, encodeOptions,
  normalizeSchema, validateSchema,
} from "../codec.js";
import { WIRE_PREFIX, wireBytes } from "./wire.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RESOURCES = path.resolve(HERE, "../../../Tests/SchemerTests/Resources");
const golden = JSON.parse(fs.readFileSync(path.join(RESOURCES, "schemer_golden.json"), "utf8"));
const FIXTURE_DIR = process.env.SCHEMER_MODEL_DIR ?? path.join(HERE, "fixtures", "model");
// The native core is Core ML on macOS and LiteRT everywhere else.
const BACKEND = process.platform === "darwin" ? "coreml" : "litert";

const schema = {
  merchant: { type: "string", describe: "the shop or vendor" },
  amount: { type: "number", describe: "total paid" },
  reimbursable: "boolean",
  category: { type: "label", values: ["food", "travel"] },
  when: "datetime",
  attendees: { type: "array", nullable: false },
};

// ---------------------------------------------------------------- codec

test("object and array schema spellings agree", () => {
  const a = normalizeSchema(schema);
  const b = normalizeSchema(a);
  assert.deepEqual(a, b);
  assert.deepEqual(a.map((f) => f.name),
    ["merchant", "amount", "reimbursable", "category", "when", "attendees"]);
  // A bare type string is shorthand for { type }.
  assert.equal(a[2].type, "boolean");
});

test("validation rejects what the runtime cannot honor", () => {
  assert.throws(() => validateSchema(normalizeSchema({ a: "nonsense" })), /unknown type/);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "label" } })), /no values/);
  assert.throws(() => validateSchema(normalizeSchema([{ name: "a", type: "string" },
    { name: "a", type: "number" }])), /duplicate/);
  const many = Array.from({ length: MAX_LABEL_VALUES + 1 }, (_, i) => `v${i}`);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "label", values: many } })),
    /at most 16/);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "string", min: 1 } })), /min/);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "number", max: NaN } })), /max/);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "number", min: 5, max: 1 } })), /above/);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "number", unit: 3 } })), /unit/);
  assert.throws(() => validateSchema(normalizeSchema({ a: { type: "number", nullable: "no" } })),
    /nullable/);
});

test("the encoder still writes the bytes the Swift suite reads", () => {
  // Tests/SchemerTests/Resources/schemer_wire.* are what this encoder wrote;
  // WireTests.swift decodes them. A change here without regenerating them (and
  // the Swift reader agreeing) is a wire break between the SDKs.
  const { input, options } = wireBytes();
  assert.deepEqual(input, fs.readFileSync(`${WIRE_PREFIX}.input`));
  assert.deepEqual(options, fs.readFileSync(`${WIRE_PREFIX}.options`));
});

test("nullable crosses as three states, and a number carries its range", () => {
  const fields = validateSchema(normalizeSchema({
    a: { type: "number", min: 0, unit: "kg" },
    b: { type: "string", nullable: false },
    c: { type: "string", nullable: true },
  }));
  const r = new FfiReader(encodeInput("t", fields));
  assert.equal(r.str(), "t");
  assert.equal(r.u32(), 3);
  assert.equal(r.str(), "a"); assert.equal(r.u32(), 1); assert.equal(r.str(), "");
  assert.equal(r.u32(), 2, "not stated");
  assert.equal(r.u32(), 1); assert.equal(r.f64(), 0);
  assert.equal(r.u32(), 0); r.f64();
  assert.equal(r.str(), "kg");
  assert.equal(r.str(), "b"); assert.equal(r.u32(), 0); r.str(); assert.equal(r.u32(), 0);
  assert.equal(r.str(), "c"); assert.equal(r.u32(), 0); r.str(); assert.equal(r.u32(), 1);
});

test("an array of objects takes either spelling of its properties, and validates them", () => {
  const a = normalizeSchema({ lines: { type: "array", items: { type: "object", properties: {
    item: "string", quantity: { type: "number", min: 1 } } } } });
  const b = normalizeSchema([{ name: "lines", type: "array", items: { type: "object", properties: [
    { name: "item", type: "string" }, { name: "quantity", type: "number", min: 1 }] } }]);
  assert.deepEqual(a, b);
  assert.deepEqual(a[0].items.properties.map((f) => f.name), ["item", "quantity"]);
  const nest = (props) => ({ o: { type: "array", items: { type: "object", properties: props } } });
  assert.throws(() => validateSchema(normalizeSchema(nest({ a: "string", b: { type: "label" } }))),
    /no values/);
  assert.throws(() => validateSchema(normalizeSchema(nest({ i: nest({ a: "string" }).o }))),
    /inside objects/);
  // A plain array of strings is still type 5.
  const r = new FfiReader(encodeInput("t", validateSchema(normalizeSchema({ tags: "array" }))));
  r.str(); r.u32(); r.str();
  assert.equal(r.u32(), 5);
});

test("the objects result kind decodes to plain objects", () => {
  const fields = validateSchema(normalizeSchema({ lines: { type: "array", items: {
    type: "object", properties: { item: "string", quantity: "number" } } }, n: "number" }));
  const w = new FfiWriter().u32(2);
  w.u32(7).u32(2);
  w.u32(2).str("item").u32(1).str("desk").str("quantity").u32(2).f64(2);
  w.u32(1).str("item").u32(1).str("lamp");
  w.u32(2).f64(3);
  assert.deepEqual(decodeExtraction(new FfiReader(w.done()), fields), {
    lines: [{ item: "desk", quantity: 2 }, { item: "lamp" }],
    n: 3,
  });
});

test("the anchor is the device's day", () => {
  const day = (d) => `today=${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${
    String(d.getDate()).padStart(2, "0")}`;
  assert.equal(new FfiReader(encodeOptions({})).str(), day(new Date()));
  // Local midnight is the local day, whatever UTC day it falls on.
  assert.equal(new FfiReader(encodeOptions({ now: new Date(2026, 6, 5) })).str(), "today=2026-07-05");
  assert.equal(new FfiReader(encodeOptions({ now: new Date(2026, 6, 5, 23, 59) })).str(),
    "today=2026-07-05");
  assert.equal(new FfiReader(encodeOptions({ now: "2026-07-05" })).str(), "today=2026-07-05");
});

test("a trailing truncated flag decodes to the symbol, and its absence to nothing", () => {
  const fields = validateSchema(normalizeSchema({ a: "string" }));
  const cut = decodeExtraction(new FfiReader(new FfiWriter().u32(1).u32(0).u32(1).done()), fields);
  assert.equal(cut[TRUNCATED], true);
  assert.equal(JSON.stringify(cut), '{"a":null}');
  const whole = decodeExtraction(new FfiReader(new FfiWriter().u32(1).u32(0).u32(0).done()), fields);
  assert.equal(whole[TRUNCATED], undefined);
  const old = decodeExtraction(new FfiReader(new FfiWriter().u32(1).u32(0).done()), fields);
  assert.equal(old[TRUNCATED], undefined);
});

test("Schemer.validate checks a schema with no model", async () => {
  const { Schemer } = await import("../node.js");
  assert.throws(() => Schemer.validate({ a: { type: "label", values: [] } }), TypeError);
  Schemer.validate({ a: "string", n: { type: "number", min: 0, max: 5 } });
});

test("result payload decodes every kind, null included", () => {
  const fields = validateSchema(normalizeSchema(schema));
  const w = new FfiWriter().u32(6);
  w.u32(1).str("Blue Bottle");             // string
  w.u32(2).f64(18.5);                      // number
  w.u32(0);                                // null, a real answer
  w.u32(5).str("food");                    // label
  w.u32(4).str("2026-07-06T09:30");        // datetime
  w.u32(6).u32(2); w.str("Anna"); w.str("Bo");
  assert.deepEqual(decodeExtraction(new FfiReader(w.done()), fields), {
    merchant: "Blue Bottle",
    amount: 18.5,
    reimbursable: null,
    category: "food",
    when: "2026-07-06T09:30",
    attendees: ["Anna", "Bo"],
  });
});

// ---------------------------------------------------------------- the model

/** The reference writes "" for an absent non-nullable string: the same answer as null. */
function same(got, want) {
  if (typeof got === "number" && typeof want === "number") return Math.abs(got - want) < 1e-6;
  if ((got === "" || got === null) && (want === "" || want === null)) return true;
  return JSON.stringify(got) === JSON.stringify(want);
}

let schemer;
let loadError;
try {
  const { Schemer } = await import("../node.js");
  schemer = await Schemer.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
} catch (e) {
  loadError = e;
}
const modelOpts = schemer ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 160)}` };

// The golden was made on an M1; every ARM64 host measured matches it on every
// field (2% allowed). On x86_64 the LiteRT files' dynamic-range int8 runs on
// different kernels, which round a field on a decision boundary the other way
// (5 of 115 on a Linux runner), so 10% there. Each is printed. The Swift
// suite's Golden.allowedDisagreements says the same.
const NATIVE_SLACK = process.arch === "x64" ? 0.10 : 0.02;

test("every golden case matches the reference for this backend", modelOpts, async () => {
  let fields = 0;
  const differ = [];
  for (const c of golden.cases) {
    const out = await schemer.extract(c.text, c.schema, { now: c.now });
    assert.deepEqual(Object.keys(out), c.schema.map((f) => f.name), `${c.id}: schema order`);
    for (const f of c.schema) {
      const want = c.expected[BACKEND][f.name];
      if (!same(out[f.name], want)) {
        differ.push(`${c.id}.${f.name}: got ${JSON.stringify(out[f.name])}, reference ${JSON.stringify(want)}`);
      }
      fields += 1;
    }
  }
  assert.ok(fields > 100);
  for (const d of differ) console.log(`schemer differs from the reference: ${d}`);
  assert.ok(differ.length <= Math.ceil(fields * NATIVE_SLACK),
    `${differ.length} of ${fields} fields differ:\n${differ.join("\n")}`);
});

test("the object spelling of a schema answers like the array spelling", modelOpts, async () => {
  const c = golden.cases.find((x) => x.id === "en-invoice-range");
  const object = Object.fromEntries(c.schema.map(({ name, ...spec }) => [name, spec]));
  assert.deepEqual(
    await schemer.extract(c.text, object, { now: c.now }),
    await schemer.extract(c.text, c.schema, { now: c.now }));
});

test("now pins relative dates", modelOpts, async () => {
  const text = "Remind me to call the dentist tomorrow at 9:30.";
  const s = { when: { type: "datetime", describe: "when to be reminded" } };
  assert.equal((await schemer.extract(text, s, { now: "2026-03-10" })).when, "2026-03-11T09:30");
  assert.equal((await schemer.extract(text, s, { now: new Date(2026, 11, 31, 12) })).when,
    "2027-01-01T09:30");
});

test("an empty schema returns an empty object without running the model", modelOpts, async () => {
  assert.deepEqual(await schemer.extract("anything", {}), {});
});

test("a bad schema rejects before running", modelOpts, async () => {
  await assert.rejects(schemer.extract("x", { a: { type: "label", values: [] } }), TypeError);
});

test("calls bill through a group and the usage flush resolves", modelOpts, async () => {
  const c = golden.cases[0];
  const out = await schemer.withCallGroup((group) =>
    schemer.extract(c.text, c.schema, { now: c.now, group }));
  assert.equal(Object.keys(out).length, c.schema.length);
  assert.equal(await schemer.flushTelemetry(), true);
  assert.equal(schemer.isDownloaded(), true);
});

test.after(() => schemer?.dispose());
