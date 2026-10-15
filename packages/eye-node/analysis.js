// Eye's result: tags with confidences (0.5 the recommended cutoff, 0.9 strict, for every tag), scores, people,
// pets, faces, crops, a rotation fix and an embedding. The JSON it is built from is the schema every SDK stores
// (Sources/Eye/Analysis.swift), so `JSON.stringify(analysis)` and `Analysis.fromJSON` round-trip, across platforms.

const LEVELS = { recommended: 0.5, strict: 0.9 };

function cutoff(level) {
  const c = LEVELS[level];
  if (c === undefined) throw new TypeError(`unknown level "${level}" (expected recommended or strict)`);
  return c;
}

/** One face in the photo, with its tags. */
export class Face {
  constructor(json) {
    this.box = json.box;
    this.detectionConfidence = json.detection_confidence;
    this.landmarks = json.landmarks;
    this.pose = json.pose;
    this.quality = json.quality;
    this.confidences = json.tags;
  }

  confidence(tag) { return this.confidences[tag] ?? null; }

  has(tag, level = "recommended") { return (this.confidences[tag] ?? 0) >= cutoff(level); }

  toJSON() {
    const { box, landmarks, pose, quality } = this;
    return { box, detection_confidence: this.detectionConfidence, landmarks, pose, quality, tags: this.confidences };
  }
}

export class Analysis {
  #json;

  constructor(json, details = null) {
    this.#json = json;
    this.model = json.model;
    this.width = json.width;
    this.height = json.height;
    this.confidences = json.tags;
    this.kind = json.kind ?? null;
    this.scores = json.scores ?? null;
    this.rotation = json.rotation ?? null;
    this.embedding = json.embedding ? Float32Array.from(json.embedding) : null;
    this.people = json.people ?? null;
    this.pets = json.pets ?? null;
    this.faces = json.faces ? json.faces.map((f) => new Face(f)) : null;
    this.crops = json.crops ?? null;
    this.details = details;
  }

  /** An analysis stored with `JSON.stringify` (or by the Swift or Kotlin SDK): a string or the parsed object. */
  static fromJSON(json) {
    return new Analysis(typeof json === "string" ? JSON.parse(json) : json);
  }

  /** The photo's confidence for `tag`, `null` when it was not computed. */
  confidence(tag) { return this.confidences[tag] ?? null; }

  /** Whether `tag` reaches `level` ("recommended" 0.5, "strict" 0.9). */
  has(tag, level = "recommended") { return (this.confidences[tag] ?? 0) >= cutoff(level); }

  /** The tags at or above `level`, most confident first. */
  tags(level = "recommended") {
    const c = cutoff(level);
    return Object.entries(this.confidences).filter(([, v]) => v >= c)
      .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([k]) => k);
  }

  /** The best crop with this width-to-height ratio (1 square, 16 / 9 a banner), in 0..1 of the image. */
  bestCrop(aspect) {
    const crops = this.crops;
    if (!crops || !crops.length || !(aspect > 0)) return null;
    const px = (b) => ((b.x1 - b.x0) * this.width) / Math.max((b.y1 - b.y0) * this.height, 1e-9);
    const fit = crops.find((c) => Math.abs(Math.log(px(c.box) / aspect)) <= Math.log(1.1));
    if (fit) return fit.box;
    const b = crops[0].box;
    let w = b.x1 - b.x0, h = b.y1 - b.y0;
    const target = (aspect * this.height) / this.width;
    if (w / h > target) w = h * target; else h = w / target;
    if (w > 1) { h /= w; w = 1; }
    if (h > 1) { w /= h; h = 1; }
    const cx = Math.min(Math.max((b.x0 + b.x1) / 2, w / 2), 1 - w / 2);
    const cy = Math.min(Math.max((b.y0 + b.y1) / 2, h / 2), 1 - h / 2);
    return { x0: cx - w / 2, y0: cy - h / 2, x1: cx + w / 2, y1: cy + h / 2 };
  }

  /** Cosine similarity of the two embeddings, -1..1; near-duplicates are above about 0.9. */
  similarity(other) {
    const a = this.embedding, b = other.embedding;
    if (!a || !b || a.length !== b.length) return null;
    let s = 0;
    for (let i = 0; i < a.length; i++) s += a[i] * b[i];
    return s;
  }

  /** The stored form (everything but `details`). */
  toJSON() { return this.#json; }

  /** @internal */
  get duplicateRule() { return this.#json.duplicates ?? null; }
}

/** No closed eyes, then face quality to a tenth, then keeper (as the Swift SDK). */
function rank(a) {
  const faces = (a.faces ?? []).filter((f) => f.detectionConfidence >= 0.5);
  const area = (f) => (f.box.x1 - f.box.x0) * (f.box.y1 - f.box.y0);
  const total = faces.reduce((s, f) => s + area(f), 0);
  const quality = faces.length ? faces.reduce((s, f) => s + f.quality * area(f), 0) / Math.max(total, 1e-9) : 0.5;
  return [a.has("eyes_closed") ? 0 : 1, Math.round(quality * 10) / 10, a.scores?.keeper ?? 0];
}

function compare(x, y) {
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

/** The index of the photo to keep from a set: no closed eyes, then the best faces, then keeper. */
export function best(analyses) {
  let out = null;
  analyses.forEach((a, i) => { if (out === null || compare(rank(a), rank(analyses[out])) > 0) out = i; });
  return out;
}

/** Photos ranked by similarity to `photo`, most similar first: [{ index, similarity }]. */
export function similar(photo, analyses, { limit = 20 } = {}) {
  return analyses.map((a, index) => ({ index, similarity: photo.similarity(a) }))
    .filter((x) => x.similarity !== null).sort((a, b) => b.similarity - a.similarity).slice(0, Math.max(0, limit));
}

/**
 * Groups of near-duplicates, as indices into `analyses`, each at least two photos, best first. With `dates`
 * (capture times in seconds, any epoch; null for unknown), only photos taken within the model's window of each
 * other count.
 */
export function duplicates(analyses, { dates = null } = {}) {
  const n = analyses.length;
  const parent = Array.from({ length: n }, (_, i) => i);
  const root = (i) => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
  const order = dates
    ? [...Array(n).keys()].filter((i) => i < dates.length && dates[i] != null).sort((a, b) => dates[a] - dates[b])
    : [...Array(n).keys()];
  order.forEach((i, k) => {
    const rule = analyses[i].duplicateRule;
    if (!rule || !analyses[i].embedding) return;
    for (const j of order.slice(k + 1)) {
      if (dates) {
        const dt = dates[j] - dates[i];
        if (dt > Math.max(rule.window_seconds, rule.window_seconds_people)) break;
        const people = analyses[i].has("people") || analyses[j].has("people");
        if (dt > (people ? rule.window_seconds_people : rule.window_seconds)) continue;
      }
      const s = analyses[i].similarity(analyses[j]);
      if (s !== null && s >= rule.similarity) parent[root(j)] = root(i);
    }
  });
  const groups = new Map();
  for (let i = 0; i < n; i++) {
    if (!analyses[i].embedding) continue;
    const r = root(i);
    if (!groups.has(r)) groups.set(r, []);
    groups.get(r).push(i);
  }
  return [...groups.values()].filter((g) => g.length > 1)
    .map((g) => g.sort((a, b) => compare(rank(analyses[b]), rank(analyses[a]))))
    .sort((a, b) => a[0] - b[0]);
}
