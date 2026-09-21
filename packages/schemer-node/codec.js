// Schemer's FFI payload schemas: the text and schema a run takes, the options
// beside it, and the typed values it returns.
//
// These are the only model-specific part of talking to the core, and both
// cores speak the same payloads - the native `dal_run` (node.js) and the
// WebAssembly `run` (browser.js) - so they live here once instead of in each
// entry point. Mirrors the reader/writer in Sources/Schemer/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Schemer, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "schemer";

export const PACKAGE_NAME = "@desert-ant-labs/schemer";

/** Field types, in the wire order Sources/Schemer/Binding.swift reads. */
const TYPES = ["string", "number", "boolean", "datetime", "label", "array"];

/** Result kinds, in the wire order Binding.swift writes. Index 0 is `null`,
 *  which is a real answer here rather than a failure: it means the text did
 *  not state the field. */
const KINDS = [null, "string", "number", "boolean", "datetime", "label", "array", "objects"];

/** Wire type 6: an array whose items are objects. */
const OBJECTS = 6;

/** The compiled label graph takes a fixed candidate count. */
export const MAX_LABEL_VALUES = 16;

/**
 * Normalize the two accepted schema spellings into an ordered field list: an
 * array of `{name, type, ...}`, or an object keyed by field name. Both are
 * natural in JS, and accepting either keeps the check out of the API surface.
 *
 * Object key order is insertion order in every engine that matters, and field
 * order is the order results come back in, so this is stable.
 */
export function normalizeSchema(schema) {
  const fields = Array.isArray(schema)
    ? schema.map((f) => ({ ...f }))
    : Object.entries(schema ?? {}).map(([name, spec]) =>
      typeof spec === "string" ? { name, type: spec } : { name, ...spec });
  // An array of objects, in JSON Schema's spelling:
  //   { type: "array", items: { type: "object", properties: {...} } }
  // Its properties take either spelling of a schema, recursively.
  for (const f of fields) {
    const props = f.items?.properties;
    if (f.type === "array" && props != null) {
      f.items = { ...f.items, type: "object", properties: normalizeSchema(props) };
    }
  }
  return fields;
}

const isObjects = (f) => f.type === "array" && Array.isArray(f.items?.properties);

/** Reject what the runtime cannot honor, before any model runs. */
export function validateSchema(fields, nested = false) {
  const seen = new Set();
  for (const f of fields) {
    if (!f?.name) throw new TypeError("every field needs a name");
    if (seen.has(f.name)) throw new TypeError(`duplicate field name '${f.name}'`);
    seen.add(f.name);
    if (TYPES.indexOf(f.type) < 0) {
      throw new TypeError(`field '${f.name}' has unknown type '${f.type}'`);
    }
    for (const bound of ["min", "max"]) {
      if (f[bound] != null && (f.type !== "number" || !Number.isFinite(f[bound]))) {
        throw new TypeError(`field '${f.name}': '${bound}' must be a finite number on a number field`);
      }
    }
    if (f.min != null && f.max != null && f.min > f.max) {
      throw new TypeError(`field '${f.name}': 'min' ${f.min} is above 'max' ${f.max}`);
    }
    if (f.unit != null && (f.type !== "number" || typeof f.unit !== "string")) {
      throw new TypeError(`field '${f.name}': 'unit' must be a string on a number field`);
    }
    if (f.nullable != null && typeof f.nullable !== "boolean") {
      throw new TypeError(`field '${f.name}': 'nullable' must be a boolean`);
    }
    if (isObjects(f)) {
      if (nested) {
        throw new TypeError(`field '${f.name}' nests objects inside objects, which is not supported`);
      }
      validateSchema(f.items.properties, true);
    }
    if (f.type === "label") {
      const n = f.values?.length ?? 0;
      if (n === 0) throw new TypeError(`label field '${f.name}' has no values`);
      if (n > MAX_LABEL_VALUES) {
        throw new TypeError(
          `label field '${f.name}' has ${n} values; the compiled label graph `
          + `takes at most ${MAX_LABEL_VALUES}`);
      }
    }
  }
  return fields;
}

/** Input payload: the text, then the field count, then each field. Mirrors
 *  Schemer's `run(input:options:)` in Sources/Schemer/Binding.swift. */
export function encodeInput(text, fields) {
  return encodeFields(new FfiWriter().str(String(text ?? "")), fields).done();
}

function encodeFields(w, fields) {
  w.u32(fields.length);
  for (const f of fields) {
    // nullable is three-way on the wire: 0 false, 1 true, 2 not stated.
    // Stating it is not the same as the default; see Binding.swift.
    w.str(f.name)
      .u32(isObjects(f) ? OBJECTS : TYPES.indexOf(f.type))
      .str(f.describe ?? "")
      .u32(f.nullable === false ? 0 : f.nullable === true ? 1 : 2);
    if (f.type === "label") {
      w.u32(f.values.length);
      for (const v of f.values) w.str(String(v));
    }
    if (f.type === "number") {
      w.u32(f.min == null ? 0 : 1).f64(f.min ?? 0)
        .u32(f.max == null ? 0 : 1).f64(f.max ?? 0)
        .str(f.unit ?? "");
    }
    if (isObjects(f)) encodeFields(w, f.items.properties);
  }
  return w;
}

/**
 * Options payload: `string anchor`, always written here: the core would read
 * an empty one as its own clock, and in the browser it does not know the
 * device's time zone.
 *
 * `now` is a Date or a `YYYY-MM-DD` string, default the device clock. A Date
 * becomes the day it falls on in the device's time zone ("yesterday" is the
 * day before the user's today, which a UTC day misses around midnight). The
 * model never learns date arithmetic: the runtime hands it `today=YYYY-MM-DD`
 * and the datetime head decodes an offset from it, so pinning this makes
 * results reproducible.
 */
export function encodeOptions({ now }) {
  let anchor;
  if (typeof now === "string" && now) {
    anchor = now.startsWith("today=") ? now : `today=${now.slice(0, 10)}`;
  } else {
    const d = now instanceof Date ? now : new Date();
    const pad = (n, w) => String(n).padStart(w, "0");
    anchor = `today=${pad(d.getFullYear(), 4)}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}`;
  }
  return new FfiWriter().str(anchor).done();
}

/**
 * The key an extraction carries its truncation flag under: a symbol, so it
 * can never collide with a field name and stays out of JSON.
 */
export const TRUNCATED = Symbol.for("@desert-ant-labs/schemer.truncated");

/**
 * Result payload: `u32 fieldCount`, then each field's kind and body. `r` is an
 * FfiReader already positioned at the payload. Fields come back in schema
 * order, so they zip against what was written rather than matching on name.
 */
export function decodeExtraction(r, fields) {
  const count = r.u32();
  const out = {};
  for (let i = 0; i < count; i += 1) {
    const name = fields[i]?.name ?? `field${i}`;
    const v = decodeValue(r);
    // A kind this SDK does not know is a core newer than the package: report
    // the field as absent rather than half-decoding the rest.
    if (v === UNKNOWN) { out[name] = null; return out; }
    out[name] = v;
  }
  if (r.hasRemaining() && r.u32() !== 0) out[TRUNCATED] = true;
  return out;
}

const UNKNOWN = Symbol("unknown kind");

function decodeValue(r) {
  const kind = KINDS[r.u32()];
  switch (kind) {
    case null: return null;
    case "string":
    case "datetime":
    case "label": return r.str();
    case "number": return r.f64();
    case "boolean": return r.u32() !== 0;
    case "array": return Array.from({ length: r.u32() }, () => r.str());
    case "objects": {
      // An item holds only the properties it states, in schema order.
      const items = [];
      for (let n = r.u32(); n > 0; n -= 1) {
        const item = {};
        for (let e = r.u32(); e > 0; e -= 1) {
          const key = r.str();
          const v = decodeValue(r);
          if (v === UNKNOWN) return UNKNOWN;
          item[key] = v;
        }
        items.push(item);
      }
      return items;
    }
    default: return UNKNOWN;
  }
}
