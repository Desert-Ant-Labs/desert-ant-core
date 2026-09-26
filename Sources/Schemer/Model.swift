// The extraction pipeline: tokenize, encode, decode, harness.
//
// Holds four sessions and runs them per field. Names no backend; `ModelAssets`
// already resolved which one this platform uses. The public facade is
// `Schemer.swift`.

import DesertAnt
import Foundation

final class Model: @unchecked Sendable {

    let tokenizer: SchemerTokenizer
    let embeddings: EmbeddingTable
    private let assets: ModelAssets
    /// Sessions, made on first use and retained. Guarded because `Model` is
    /// not an actor: a session is expensive to create and must not be created
    /// twice, but runs against it are safe.
    private let sessions = SessionCache()
    private let queryCache = QueryCache(capacity: 256)
    /// Decode outputs, in the order the graph declares them.
    let decodeOutputs: [String]


    /// Separator between the anchor, the schema summary and the text in the
    /// joint input. Part of the trained contract, not a formatting choice.
    static let separator = " ||| "

    init(assets: ModelAssets) throws {
        self.tokenizer = try SchemerTokenizer(data: assets.tokenizer)
        self.embeddings = try EmbeddingTable(data: assets.embeddings)
        self.assets = assets
        self.decodeOutputs = Self.decodeOutputNames
    }

    /// Extract every field in `schema` from `text`.
    ///
    /// - Parameter now: the date relative expressions resolve against.
    ///   Defaults to today; pass a fixed date to make results reproducible.
    func extract(from text: String, schema: Schema,
                        now: Date = Date()) async throws -> Extraction {
        try schema.validate()
        let t0 = Date()
        let anchor = Self.anchorString(now)
        var out: [(String, Value)] = []
        var truncated = false
        // A datetime sibling turns a trailing temporal expression in a string
        // span into cross-field leakage, so the trim is schema-dependent.
        let hasDT = schema.fields.contains { if case .datetime = $0.kind { return true }
                                             else { return false } }
        for field in schema.fields {
            if case .objects(let properties) = field.kind {
                out.append((field.name, try await objects(text: text, properties: properties,
                                                          anchor: anchor, truncated: &truncated)))
                continue
            }
            out.append((field.name,
                        try await extractOne(text: text, field: field, anchor: anchor,
                                             hasDatetimeSibling: hasDT, truncated: &truncated)))
        }
        return Extraction(values: out, duration: Date().timeIntervalSince(t0), truncated: truncated)
    }

    /// The day `d` falls on where the device is. "Yesterday" means the day
    /// before the user's today, so a UTC day would be off by one for the
    /// hours around midnight on either side of Greenwich.
    static func anchorString(_ d: Date, in timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "today=%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    /// `today=YYYY-MM-DD` -> YYYY. The datetime head decodes a year OFFSET
    /// from this, so it is not optional context.
    static func components(ofAnchor anchor: String) -> DateComponents {
        let parts = anchor.split(separator: "=").last.map(String.init) ?? anchor
        let f = parts.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = f.count > 0 ? f[0] : 2026
        c.month = f.count > 1 ? f[1] : 1
        c.day = f.count > 2 ? f[2] : 1
        return c
    }

    static func year(ofAnchor anchor: String) -> Int {
        guard let eq = anchor.firstIndex(of: "=") else { return 2026 }
        return Int(anchor[anchor.index(after: eq)...].prefix(4)) ?? 2026
    }

    // MARK: - One field

    /// What the graphs saw and said for one field, before the harness ran.
    struct Stage {
        let heads: Heads
        /// Tokenization of the TEXT ALONE; index with `i - shift`.
        let tokens: [TokenSpan]
        let shift: Int
        let textStart: Int
        let validEnd: Int
        let window: Int
        /// Whether the joint input ran past the longest window, so the end
        /// of the text was never read.
        let truncated: Bool
    }

    func stage(text: String, field: Field, anchor: String) async throws -> Stage {
        // Joint input: the encoder sees the schema from layer 0, which is what
        // makes the text representation field-aware rather than generic.
        let prefix = anchor + Self.separator + field.summary
        let joint = prefix + Self.separator + text

        let (jointTokens, truncated) = tokenizer.encodeReportingTruncation(
            joint, maxLength: Shapes.windows.last!)
        let textStart = tokenizer.encode(prefix + Self.separator,
                                         maxLength: Shapes.windows.last!).count - 1
        let ids = tokenizer.slim(jointTokens.map(\.id))

        // Char offsets come from tokenizing the TEXT ALONE, and a joint token
        // index maps into it as `i - (textStart - 1)`.
        //
        // NOT from slicing the joint offsets by the prefix length: the joint
        // string segments differently across the separator, so the text region
        // shifts by a token and every extracted span lands a few characters
        // late ("Bottle" for "Blue Bottle"). The shift varies per record,
        // which is what makes it read as model fuzziness rather than an
        // indexing bug. Mirrors `pts = a - (text_start - 1)` in
        // training/v60/score_heldout.py.
        let textTokens = tokenizer.encode(text, maxLength: Shapes.windows.last!)

        let window = Shapes.window(for: ids.count)
        let states = try await runEncoder(ids: ids, window: window)
        let (queryStates, queryBias) = try await runQuery(field.query)
        // The datetime and number heads get their own query encodings only
        // when their outputs are read. For any other field those heads still
        // run inside the fused decode graph, but nothing consumes them, so the
        // reader's query stands in and two encoder passes per field are saved.
        // The datetime and number heads cross-attend over their OWN schema
        // strings, not the reader's: they carry nullable/relative_to and
        // min/max/unit respectively. Feeding them the reader's query is a
        // silent loss on exactly the two heads that most depend on the spec.
        let (dtStates, dtBias) = field.isDatetime
            ? try await runQuery(field.datetimeQuery) : (queryStates, queryBias)
        let (numStates, numBias) = field.isNumber
            ? try await runQuery(field.numberQuery) : (queryStates, queryBias)

        let validEnd = min(ids.count, window)
        let poolW = Masks.pooling(start: textStart, end: validEnd, length: window)

        let decode = try await session("dec\(window)") {
            try await assets.makeDecoder(window)
        }
        let inputs = ["text_states": states, "query_states": queryStates,
                      "query_bias": queryBias, "pool_w": poolW,
                      "dt_query": dtStates, "dt_bias": dtBias,
                      "num_query": numStates, "num_bias": numBias]
        let outs = try await decode.run(inputs: inputs, outputs: decodeOutputs)

        return Stage(heads: try Heads(names: decodeOutputs, tensors: outs),
                     tokens: textTokens, shift: textStart - 1,
                     textStart: textStart, validEnd: validEnd, window: window,
                     truncated: truncated)
    }

    private func extractOne(text: String, field: Field, anchor: String,
                            hasDatetimeSibling: Bool = false,
                            truncated: inout Bool) async throws -> Value {
        let s = try await stage(text: text, field: field, anchor: anchor)
        if s.truncated { truncated = true }
        return try await decodeValue(s, text: text, field: field, modelAnchor: anchor,
                                     hasDatetimeSibling: hasDatetimeSibling)
    }

    /// Get or make a session. The `make` closure runs outside the lock, so a
    /// slow load does not block an unrelated window; a duplicate load is
    /// possible under contention and is discarded.
    private func session(_ key: String,
                         _ make: () async throws -> any InferenceSession) async throws
        -> any InferenceSession {
        if let cached = await sessions.get(key) { return cached }
        return await sessions.put(key, try await make())
    }

    /// Load and specialize every graph function, then run each once.
    ///
    /// On the Neural Engine the first use of a function compiles it for the
    /// device, and that cost is per app install, not per launch: measured on
    /// an M1, ~33 s before the first short record and ~92 s before the first
    /// long one. Doing it here moves that off the user's first extraction.
    /// `progress` reports 0...1 over the steps.
    func prewarm(progress: @Sendable (Double) -> Void) async throws {
        let steps = Double(Shapes.windows.count * 2 + 2)
        var done = 0.0
        func step() { done += 1; progress(done / steps) }

        _ = try await runQuery("warm")
        step()
        for w in Shapes.windows {
            let states = try await runEncoder(ids: [2, 1], window: w)
            step()
            let (q, qb) = try await runQuery("warm")
            let dec = try await session("dec\(w)") { try await assets.makeDecoder(w) }
            _ = try await dec.run(
                inputs: ["text_states": states, "query_states": q, "query_bias": qb,
                         "pool_w": Masks.pooling(start: 0, end: 1, length: w),
                         "dt_query": q, "dt_bias": qb, "num_query": q, "num_bias": qb],
                outputs: decodeOutputs)
            step()
        }
        let lab = try await session("label") { try await assets.makeLabel() }
        let zero = Tensor(float32: [Float](repeating: 0, count: Shapes.dim), shape: [1, Shapes.dim, 1, 1])
        _ = try await lab.run(
            inputs: ["reader_rep": zero, "proto_text": zero,
                     "value_embs": Tensor(float32: [Float](repeating: 0, count: Shapes.dim * Shapes.labelValues),
                                          shape: [1, Shapes.dim, 1, Shapes.labelValues])],
            outputs: ["dual", "proto"])
        step()
    }

    func runEncoder(ids: [Int32], window: Int) async throws -> Tensor {
        let embeds = embeddings.gather(ids, length: window)
        let (g, l) = Masks.encoder(validCount: min(ids.count, window), length: window)
        let enc = try await session("enc\(window)") {
            try await assets.makeEncoder(window)
        }
        return try await enc.run(
            inputs: ["embeds": embeds, "global_bias": g, "local_bias": l],
            outputs: ["states"])[0]
    }

    /// Encode a short string with the 32-token encoder: the field query the
    /// reader attends over, and label value embeddings.
    func runQuery(_ s: String) async throws -> (Tensor, Tensor) {
        // Query encodings depend only on the string, and a schema's strings
        // repeat on every call that uses it: the field description, the
        // datetime and number schema texts, every label value. Caching them
        // turns a label field with N values from N+1 encoder dispatches per
        // call into one after the first.
        if let hit = await queryCache.get(s) { return hit }
        let result = try await encodeQuery(s)
        await queryCache.put(s, result)
        return result
    }

    private func encodeQuery(_ s: String) async throws -> (Tensor, Tensor) {
        let ids = tokenizer.slim(tokenizer.encode(s, maxLength: Shapes.query).map(\.id))
        let embeds = embeddings.gather(ids, length: Shapes.query)
        let (g, l) = Masks.encoder(validCount: ids.count, length: Shapes.query)
        let qe = try await session("query") { try await assets.makeQueryEncoder() }
        let states = try await qe.run(
            inputs: ["embeds": embeds, "global_bias": g, "local_bias": l],
            outputs: ["states"])[0]
        return (states, Masks.query(validCount: ids.count, length: Shapes.query))
    }

    /// Mean-pooled embedding of a short string, for label candidates.
    private func poolQuery(_ s: String) async throws -> [Float] {
        let ids = tokenizer.slim(tokenizer.encode(s, maxLength: Shapes.query).map(\.id))
        let (states, _) = try await runQuery(s)
        guard let v = states.float32Values else { return [] }
        var out = [Float](repeating: 0, count: Shapes.dim)
        for c in 0..<Shapes.dim {
            var acc: Float = 0
            for t in 0..<ids.count { acc += v[c * Shapes.query + t] }
            out[c] = acc / Float(ids.count)
        }
        return out
    }

    // MARK: - Per-type decoding

    /// - Parameters:
    ///   - modelAnchor: the `today=YYYY-MM-DD` the encoder was shown.
    ///   - resolveAnchor: what relative dates and the decoded year resolve
    ///     against. nil means the model anchor, which is what a caller wants.
    ///     The conformance test passes the reference's fixed DEFAULT_NOW here,
    ///     because the reference resolves against 2026-06-25 regardless of the
    ///     record - a reference bug the SDK deliberately does not reproduce.
    ///   - trustedAnchor: whether the anchor is a real "today" rather than a
    ///     default. Only a trusted anchor may overwrite the year the head
    ///     decoded (and only when the text states no year). An SDK caller's
    ///     `now` is always real, so the public path passes true; the
    ///     conformance test passes what the record actually carried.
    func decodeValue(_ s: Stage, text: String, field: Field, modelAnchor: String,
                     resolveAnchor: DateComponents? = nil, trustedAnchor: Bool = true,
                     hasDatetimeSibling: Bool = false) async throws -> Value {
        switch field.kind {
        case .boolean:  return boolean(s)
        case .string:   return string(s, text, field,
                                      hasDatetimeSibling: hasDatetimeSibling)
        case .array:    return array(s, text)
        case .number:   return number(s, text, field)
        case .datetime: return datetime(s, text,
                                        resolveAgainst: resolveAnchor ?? Self.components(ofAnchor: modelAnchor),
                                        trustedAnchor: trustedAnchor)
        case .label(let values):
            return try await labelValue(s, values: values, nullable: field.nullable)
        case .objects(let properties):
            // Not a head: `objects(text:properties:anchor:)` segments the text
            // and recurses. Reaching here means a caller skipped that route.
            return try await objects(text: text, properties: properties, anchor: modelAnchor,
                                     trustedAnchor: trustedAnchor)
        }
    }

    private func boolean(_ s: Stage) -> Value {
        let k = s.heads.argmax("bool_logits", 3)     // [absent, false, true]
        return k == 0 ? .null : .boolean(k == 2)
    }

    /// Slice a joint-token run out of the source text.
    private func slice(_ s: Stage, _ text: String, _ run: ClosedRange<Int>) -> String? {
        Levers.slice(text, tokens: s.tokens,
                     run: (run.lowerBound - s.shift)...(run.upperBound - s.shift),
                     snap: Levers.on("word_snap"))
    }

    private func string(_ s: Stage, _ text: String, _ field: Field,
                        hasDatetimeSibling: Bool) -> Value {
        // Presence gate first. The BIO tagger must always emit its best span,
        // so without an explicit absence decision an unstated field leaks the
        // nearest lookalike (a phone field returning the email).
        // The gate applies regardless of `nullable`; nullable only decides
        // whether an absent field reads as null or as "". Skipping the gate
        // for non-nullable fields lets them leak the nearest lookalike.
        let p = s.heads["string_presence"]
        if Harness.softmax2(p[1], p[0]) >= 0.5 { return .null }
        let runs = bio(s, "string_bio")
        // Highest mean B/I probability, not longest: `_bio_best_span` scores
        // runs by tag confidence, and picking by length prefers a long
        // low-confidence span over the short confident one the model meant.
        var best = Harness.bestRun(s.heads["string_bio"], window: s.window, runs: runs)
        if best == nil, Levers.on("forced_span") {
            best = Levers.forcedRun(s.heads["string_bio"], window: s.window,
                                    start: s.textStart, end: s.validEnd)
        }
        guard let best, let raw = slice(s, text, best) else { return .null }
        let v = Harness.trimSpanTail(raw, temporalSiblings: hasDatetimeSibling)
        // Format gate: a hard violation on a format-named field means the
        // value is not in the text (an email span in a phone field).
        guard !v.isEmpty, Harness.formatGateOK(field: field.name, value: v)
        else { return .null }
        return .string(v)
    }

    private func array(_ s: Stage, _ text: String) -> Value {
        // An absent array is the EMPTY array, not null. The reference returns
        // `[]` from the v73 presence gate and from a no-span decode alike;
        // `null` would be a different answer to the scorer.
        let p = s.heads["array_presence"]
        if Harness.softmax2(p[1], p[0]) >= 0.5 { return .array([]) }
        return .array(bio(s, "array_bio")
            .compactMap { slice(s, text, $0) }
            .filter { !$0.isEmpty }
            // A lone function word is never an item ("the" between two
            // symptoms): a tagging slip between two runs.
            .filter { !Levers.on("array_function_words") || !Harness.trailFunctionWords.contains($0.lowercased()) })
    }

    private func number(_ s: Stage, _ text: String, _ field: Field) -> Value {
        guard s.textStart < s.validEnd else { return compose(s, field) }

        // Strategy A, the parse-gate: LOCATE the literal with the span
        // pointer, then parse it deterministically. The net finds the number;
        // it does not read the digits (learned digits mis-scale: 950000 as
        // 9500).
        let startLogits = s.heads["span_start"], endLogits = s.heads["span_end"]
        // Absence. The digit decoder's null logit decides it for a nullable
        // field before anything is parsed: composing a value for a field the
        // text never states was 1.0's largest number error (measured +0.06
        // on number). A trained presence gate was tried in 1.1 and did not
        // beat this (docs/swift-eval.md).
        if Levers.on("num_null_gate"), field.nullable,
           1 / (1 + expf(-(s.heads["num_null"].first ?? 0))) > 0.5 {
            return .null
        }
        // Candidate starts, best first. The first is the reference's argmax;
        // the others are only consulted when a start lands inside a date, a
        // time, a card fragment, a phone number or an identifier, which are
        // digits but never the quantity a number field asks for.
        let skip = Levers.on("num_skip_nonquantity")
        let order = (s.textStart..<s.validEnd).sorted { startLogits[$0] > startLogits[$1] }
        let nonQ = skip ? Levers.nonQuantityRanges(text) : []
        for ps in order.prefix(skip ? 5 : 1) {
            // End is the best within a SHORT window after the start, not the
            // global argmax, which pairs the start with whatever scores highest
            // anywhere in the document.
            var be = ps
            for j in ps..<min(ps + 12, s.validEnd) where endLogits[j] > endLogits[be] { be = j }
            let run = (ps - s.shift)...(be - s.shift)
            if skip, let (a, b) = Levers.range(tokens: s.tokens, run: run),
               Levers.insideNonQuantity(a, b, nonQ) {
                continue
            }
            if let raw = Harness.slice(text, tokens: s.tokens, run: run) {
                // Space-separated thousands: "950 000 kr" is cut at "950" because
                // the space is a token boundary. NBSP/thin space are normal in
                // nb/fr/sv formatting.
                if let v = Harness.parseLiteral(Harness.extendThousands(raw, in: text),
                                                min: field.minimum, max: field.maximum) {
                    return .number(v)
                }
            }
            break
        }
        // Strategy B: nothing parseable at the located span.
        return compose(s, field)
    }

    /// `compose_from_logits`, including its range handling.
    ///
    /// It returns null only when the null head fires AND the field is
    /// nullable; otherwise it always composes. The result is clamped to the
    /// schema's range and rounded to an integer when that range is wider
    /// than 1 - which is why so many reference answers are exactly `min`.
    private func compose(_ s: Stage, _ field: Field) -> Value {
        let nullLogit = s.heads["num_null"].first ?? 0
        if 1 / (1 + expf(-nullLogit)) > 0.5, field.nullable, field.explicitNullable {
            return .null
        }
        guard case .number(var v) = Harness.composeNumber(
            sign: s.heads.argmax("num_sign", 3),
            magnitude: s.heads.argmax("num_magnitude", 10),
            digits: (0..<4).map { s.heads.argmax("num_digit\($0)", 10) },
            decimalPos: s.heads.argmax("num_decimal_pos", 5)) else { return .null }
        let lo = field.minimum ?? -1e18, hi = field.maximum ?? 1e18
        v = max(lo, min(hi, v))
        if hi - lo > 1 { v = v.rounded() }
        return .number(v)
    }

    private func datetime(_ s: Stage, _ text: String, resolveAgainst anchor: DateComponents,
                          trustedAnchor: Bool) -> Value {
        // No presence gate: v79 ships with `_gate_dts` unset.

        // ISO fast-path: a SINGLE unambiguous machine timestamp is taken
        // verbatim. Exactly one, so a multi-date document does not grab a
        // distractor.
        let isos = Harness.isoTimestamp.matches(in: text, range: NSRange(text.startIndex..., in: text))
        if isos.count == 1, let m = isos.first {
            func g(_ i: Int) -> String? {
                Range(m.range(at: i), in: text).map { String(text[$0]) }
            }
            return .datetime("\(g(1)!)-\(g(2)!)-\(g(3)!)T\(g(4)!):\(g(5)!):\(g(6) ?? "00")")
        }

        if 1 / (1 + expf(-(s.heads["dt_null"].first ?? 0))) > 0.5 { return .null }
        let y = anchor.year ?? 2026
        guard var iso = Harness.datetime(
            year: Harness.year(fromClass: s.heads.argmax("dt_year", 256), anchorYear: y),
            month: s.heads.argmax("dt_month", 12) + 1,
            day: s.heads.argmax("dt_day", 31) + 1,
            hour: s.heads.argmax("dt_hour", 24),
            minute: s.heads.argmax("dt_minute", 60))
        else {
            // The head abstained, but a relative marker plus an explicit time
            // still determine the value.
            if let d = RelativeDates.resolve(text, anchor: anchor),
               let t = RelativeDates.timeOfDay(text) {
                return .datetime(String(format: "%04d-%02d-%02dT%02d:%02d",
                                        d.year!, d.month!, d.day!, t.0, t.1))
            }
            return .null
        }

        // Year correction: the year of a text date matching the composed
        // month/day beats the anchor-biased year the head decoded.
        let cm = Int(iso.dropFirst(5).prefix(2))!, cd = Int(iso.dropFirst(8).prefix(2))!
        if let yr = Harness.yearOfMatchingDate(text, month: cm, day: cd) {
            iso = String(format: "%04d", yr) + iso.dropFirst(4)
        } else if trustedAnchor,
                  Harness.anyDateYear.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil {
            iso = String(format: "%04d", y) + iso.dropFirst(4)
        }

        // A date the text writes out beats the head's month and day when the
        // text writes exactly one; its year, when written, beats the head's.
        if Levers.on("text_date") {
            let dates = Levers.textDates(text)
            let md = Set(dates.map { $0.month * 100 + $0.day })
            let cm2 = Int(iso.dropFirst(5).prefix(2))!, cd2 = Int(iso.dropFirst(8).prefix(2))!
            var target: Levers.TextDate? = nil
            if let hit = dates.first(where: { $0.month == cm2 && $0.day == cd2 && $0.year != nil }) {
                target = hit
            } else if md.count == 1, let only = dates.first {
                target = dates.first(where: { $0.year != nil }) ?? only
            }
            if let t = target {
                let yy = t.year ?? Int(iso.prefix(4))!
                iso = String(format: "%04d-%02d-%02d", yy, t.month, t.day) + iso.dropFirst(10)
            }
        }

        // A relative-day expression replaces the DATE.
        if let d = RelativeDates.resolve(text, anchor: anchor) {
            iso = String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
                + "T" + iso.split(separator: "T", maxSplits: 1)[1]
        }
        // And a time the text states outright replaces the head's TIME.
        if let (h, mi) = RelativeDates.soleTimeOfDay(text) {
            iso = iso.prefix(10) + String(format: "T%02d:%02d", h, mi)
        }
        return .datetime(iso)
    }

    private func labelValue(_ s: Stage, values: [String],
                            nullable: Bool) async throws -> Value {
        var embs = [Float](repeating: 0, count: Shapes.dim * Shapes.labelValues)
        for (i, v) in values.enumerated() {
            let p = try await poolQuery(v)
            for c in 0..<min(Shapes.dim, p.count) { embs[c * Shapes.labelValues + i] = p[c] }
        }
        let lab = try await session("label") { try await assets.makeLabel() }
        let r = try await lab.run(
            inputs: ["reader_rep": Tensor(float32: s.heads["reader_rep"],
                                          shape: [1, Shapes.dim, 1, 1]),
                     "proto_text": Tensor(float32: s.heads["proto_text"],
                                          shape: [1, Shapes.dim, 1, 1]),
                     "value_embs": Tensor(float32: embs,
                                          shape: [1, Shapes.dim, 1, Shapes.labelValues])],
            outputs: ["dual", "proto"])
        // Inference averages the two heads' softmaxes: the dual head reads,
        // the prototype head matches, and their errors are decorrelated.
        let a = softmax(Array((r[0].float32Values ?? [])[0..<values.count]))
        let b = softmax(Array((r[1].float32Values ?? [])[0..<values.count]))
        var best = 0
        for i in 0..<values.count where a[i] + b[i] > a[best] + b[best] { best = i }
        return .label(values[best])
    }

    // MARK: - Utilities

    func bio(_ s: Stage, _ key: String) -> [ClosedRange<Int>] {
        let f = s.heads[key]                       // (1, 3, 1, T) -> [3][T]
        let T = s.window
        var tags = [Int](repeating: 0, count: T)
        for t in s.textStart..<s.validEnd {
            var best = 0
            for k in 1..<3 where f[k * T + t] > f[best * T + t] { best = k }
            tags[t] = best
        }
        return Harness.bioRuns(tags: tags, validCount: s.validEnd)
    }

    private func softmax(_ xs: [Float]) -> [Float] {
        let m = xs.max() ?? 0
        let e = xs.map { expf($0 - m) }
        let s = e.reduce(0, +)
        return s > 0 ? e.map { $0 / s } : e
    }

    /// Every output the decode graph declares, in a fixed order so the port
    /// and the exporter cannot drift. Matches the sorted keys emitted by
    /// `tools/release/convert_coreml_decode_ane.py`.
    /// Every output the decode graph declares, in a fixed order so the port
    /// and the exporter cannot drift.
    ///
    /// LiteRT identifies outputs POSITIONALLY, so this list being short by one
    /// is not a missing value but a shift of everything after it. It was
    /// short by one (`dt_dow`, which nothing reads) until the LiteRT export
    /// wrote `decode_outputs.json` beside the artifacts and the two were
    /// compared. Generated from that file; do not hand-edit.
    static let decodeOutputNames: [String] = [
        "array_bio", "array_presence", "bool_logits", "dt_day", "dt_dow",
        "dt_hour", "dt_is_rel", "dt_minute", "dt_month", "dt_null",
        "dt_rel_dir", "dt_rel_kind", "dt_year", "num_decimal_pos",
        "num_digit0", "num_digit1", "num_digit2", "num_digit3",
        "num_magnitude", "num_null", "num_sign", "proto_text", "reader_rep",
        "span_end", "span_start", "string_bio", "string_presence",
    ]
}

/// Session cache. An actor rather than a lock because the loads it guards are
/// async; a duplicate load under contention is possible and is discarded.
private actor SessionCache {
    private var byKey: [String: any InferenceSession] = [:]
    func get(_ key: String) -> (any InferenceSession)? { byKey[key] }
    func put(_ key: String, _ made: any InferenceSession) -> any InferenceSession {
        if let raced = byKey[key] { return raced }
        byKey[key] = made
        return made
    }
}

/// LRU of query encodings: string -> (states, key-padding bias).
///
/// 256 entries of 768 x 32 float32 states is ~25 MB, which covers a large
/// schema's every description and label value with room for several schemas.
private actor QueryCache {
    private var entries: [String: (Tensor, Tensor)] = [:]
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func get(_ key: String) -> (Tensor, Tensor)? {
        guard let v = entries[key] else { return nil }
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        return v
    }

    func put(_ key: String, _ value: (Tensor, Tensor)) {
        if entries[key] == nil, entries.count >= capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
        entries[key] = value
        order.removeAll { $0 == key }
        order.append(key)
    }
}
