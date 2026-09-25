import Foundation
import Schemer

// Extract typed fields from text, against a schema declared at runtime.
//
//   swift run SchemerCLIExample
//   swift run SchemerCLIExample "Lunch with Sam at Nopa on Friday, 42 dollars"
//   SCHEMER_MODEL_DIR=/path/to/model swift run SchemerCLIExample

// Downloads the model on first use and caches it, unless pointed at a folder
// that already holds it.
let schemer = Schemer(directory: ProcessInfo.processInfo.environment["SCHEMER_MODEL_DIR"])

// A schema is a value. The model is schema-generic, so a new schema is a
// runtime input and needs no retraining.
let expense: Schema = [
    .string("merchant", describe: "the shop or vendor"),
    .number("amount", describe: "total paid", nullable: true, unit: "currency"),
    .boolean("reimbursable", describe: "can this be expensed"),
    .label("category", values: ["food", "travel", "office"]),
    .datetime("when", describe: "when it happened"),
    .array("attendees", describe: "people present"),
]

let samples = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : [
    "Coffee meeting at Blue Bottle with Dana and Priya yesterday, $18.50. Reimbursable.",
    "Taxi from the airport to the Hilton, 64 euros, Tuesday at 11pm.",
    // Absence is the point: nothing here answers the schema, so every field
    // comes back null rather than the nearest lookalike.
    "The weather today is mild and the train was on time.",
]

// A schema can be checked with no model, before anything is downloaded.
try expense.validate()

// The first extraction compiles the graphs for this machine's Neural Engine,
// once per install. An app does this during onboarding.
print("preparing the model (the first run compiles it for this device)...")
try await schemer.prewarm()

for text in samples {
    let out = try await schemer.extract(from: text, schema: expense)
    print("\n\(text)")
    print(out.json)
    print("  \(Int(out.duration * 1000)) ms for \(expense.fields.count) fields")
    if out.truncated { print("  warning: the text is too long, and its end was not read") }
}

// A list of objects: every line of an order, each with the properties the
// text states.
let order: Schema = [
    .string("vendor", describe: "who sent the invoice"),
    .objects("lines", properties: [
        .string("item", describe: "product"),
        .number("quantity", describe: "how many", min: 1, max: 99),
        .number("unit_price", describe: "price per unit", unit: "currency"),
    ]),
]
let invoice = "Invoice from Nordic Supplies: 2 ergonomic chairs at 189.00 each, 4 monitor arms at 35.50."
let lines = try await schemer.extract(from: invoice, schema: order)
print("\n\(invoice)")
print(lines.json)
