// The exact bytes the JS codec writes for one schema, committed as
// Tests/SchemerTests/Resources/schemer_wire.{input,options} for the Swift and
// Kotlin suites to read.
//
// Cross-language wire agreement is the real risk in a binding, and a
// round-trip inside one language cannot catch a shared misunderstanding: both
// sides can be wrong the same way. So the JS suite asserts its encoder still
// writes these bytes, and the Swift suite asserts it reads the schema they
// mean. Regenerate after a deliberate format change with:
//
//     node packages/schemer-node/test/wire.mjs
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { encodeInput, encodeOptions, normalizeSchema, validateSchema } from "../codec.js";

export const WIRE_PREFIX = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../Tests/SchemerTests/Resources/schemer_wire");

export function wireBytes() {
  const fields = validateSchema(normalizeSchema({
    merchant: { type: "string", describe: "the shop or vendor", nullable: true },
    amount: { type: "number", describe: "total paid", min: 0, max: 10000, unit: "currency" },
    reimbursable: "boolean",
    category: { type: "label", values: ["food", "travel", "office"] },
    when: "datetime",
    attendees: { type: "array", nullable: false },
    guests: { type: "number" },
    lines: {
      type: "array", describe: "order lines",
      items: { type: "object", properties: {
        item: { type: "string", describe: "product" },
        quantity: { type: "number", min: 1 },
        size: { type: "label", values: ["S", "L"], nullable: false },
      } },
    },
  }));
  return {
    input: Buffer.from(encodeInput("Coffee at Blue Bottle, $18.50", fields)),
    options: Buffer.from(encodeOptions({ now: "2026-07-05" })),
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { input, options } = wireBytes();
  writeFileSync(`${WIRE_PREFIX}.input`, input);
  writeFileSync(`${WIRE_PREFIX}.options`, options);
  console.log("wrote", WIRE_PREFIX);
}
