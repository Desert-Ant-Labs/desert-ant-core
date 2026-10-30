// What a diarization is: the turns and the speakers, and the two things a host
// does with them after the model ran. Mirrors `Diarization` in Sources/Who/Who.swift.

/** One stretch of one speaker's speech. */
export class Turn {
  constructor(speaker, start, end) {
    /** `0, 1, 2, ...` in order of first appearance. */
    this.speaker = speaker;
    /** Seconds from the start of the recording. */
    this.start = start;
    this.end = end;
  }

  get duration() {
    return this.end - this.start;
  }

  toJSON() {
    return { speaker: this.speaker, start: this.start, end: this.end };
  }
}

/** Who spoke when. */
export class Diarization {
  /**
   * @param {Turn[]} turns every turn; sorted here by start time
   * @param {number} duration the recording's length in seconds
   * @param {number} [speakerCount] the distinct speakers; from the turns when absent
   */
  constructor(turns, duration, speakerCount) {
    this.turns = [...turns].sort((a, b) => a.start - b.start || a.speaker - b.speaker);
    this.duration = duration;
    this.speakerCount = speakerCount ?? this.turns.reduce((max, t) => Math.max(max, t.speaker + 1), 0);
  }

  /** The turns of one speaker, by start time. */
  turnsOf(speaker) {
    return this.turns.filter((t) => t.speaker === speaker);
  }

  /**
   * The speakers whose speech adds up to at least `minimumShare` of the
   * recording, in their numbering here. A share of 0 keeps everyone.
   */
  speakers({ minimumShare = 0 } = {}) {
    const total = new Map();
    for (const t of this.turns) total.set(t.speaker, (total.get(t.speaker) ?? 0) + t.duration);
    const out = [];
    for (let s = 0; s < this.speakerCount; s++) {
      if ((total.get(s) ?? 0) >= minimumShare * this.duration) out.push(s);
    }
    return out;
  }

  /**
   * The same result without the speakers under `minimumShare` of the
   * recording: their turns are gone and the rest are numbered by first
   * appearance again.
   */
  keepingSpeakers({ minimumShare }) {
    const kept = new Set(this.speakers({ minimumShare }));
    if (kept.size >= this.speakerCount) return this;
    const label = new Map();
    const turns = [];
    for (const t of this.turns) {
      if (!kept.has(t.speaker)) continue;
      if (!label.has(t.speaker)) label.set(t.speaker, label.size);
      turns.push(new Turn(label.get(t.speaker), t.start, t.end));
    }
    return new Diarization(turns, this.duration, label.size);
  }

  toJSON() {
    return { turns: this.turns.map((t) => t.toJSON()), duration: this.duration, speakerCount: this.speakerCount };
  }

  /** A result stored with `JSON.stringify`, restored. */
  static fromJSON(json) {
    const o = typeof json === "string" ? JSON.parse(json) : json;
    return new Diarization(o.turns.map((t) => new Turn(t.speaker, t.start, t.end)), o.duration, o.speakerCount);
  }
}
