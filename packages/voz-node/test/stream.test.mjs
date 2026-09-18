// The streaming sources: what makes memory independent of file length.
//
// Worth testing properly because it is offset arithmetic over a binary format.
// The failure it guards against is not a crash: a header misread gives a
// plausible transcript of the wrong samples, or silently drops the tail.
import test from "node:test";
import assert from "node:assert/strict";
import { wavSource } from "../stream.js";

/** A WAV of `seconds` of a ramp, so every sample's value says where it is. */
function wav({ seconds = 1, rate = 16000, channels = 1, bits = 16, float = false,
               dataSize = null, extraChunk = false } = {}) {
  const frames = Math.round(seconds * rate);
  const bytesPerFrame = channels * (bits / 8);
  const body = frames * bytesPerFrame;
  const extra = extraChunk ? 8 + 6 : 0;                 // an odd-sized LIST
  const header = 12 + 24 + extra + 8;
  const out = new Uint8Array(header + body);
  const dv = new DataView(out.buffer);
  const tag = (at, s) => { for (let i = 0; i < 4; i++) out[at + i] = s.charCodeAt(i); };

  tag(0, "RIFF"); dv.setUint32(4, out.length - 8, true); tag(8, "WAVE");
  let at = 12;
  tag(at, "fmt "); dv.setUint32(at + 4, 16, true);
  dv.setUint16(at + 8, float ? 3 : 1, true);
  dv.setUint16(at + 10, channels, true);
  dv.setUint32(at + 12, rate, true);
  dv.setUint32(at + 16, rate * bytesPerFrame, true);
  dv.setUint16(at + 20, bytesPerFrame, true);
  dv.setUint16(at + 22, bits, true);
  at += 24;
  if (extraChunk) {
    // An odd-sized chunk before `data`: the reader must apply RIFF's pad byte,
    // or every later offset is one out and the audio decodes as noise.
    tag(at, "LIST"); dv.setUint32(at + 4, 5, true); at += 8 + 5 + 1;
  }
  tag(at, "data");
  dv.setUint32(at + 4, dataSize ?? body, true);
  at += 8;
  for (let frame = 0; frame < frames; frame++) {
    const value = (frame / frames) * 2 - 1;             // -1 .. 1 ramp
    for (let channel = 0; channel < channels; channel++) {
      const o = at + (frame * channels + channel) * (bits / 8);
      if (float) dv.setFloat32(o, value, true);
      else if (bits === 8) dv.setUint8(o, Math.round(value * 127) + 128);
      else if (bits === 16) dv.setInt16(o, Math.round(value * 32767), true);
      else if (bits === 24) {
        const v = Math.round(value * 8388607);
        dv.setUint8(o, v & 0xff); dv.setUint8(o + 1, (v >> 8) & 0xff); dv.setInt8(o + 2, v >> 16);
      } else dv.setInt32(o, Math.round(value * 2147483647), true);
    }
  }
  return new Blob([out]);
}

/** Drain a source the way the core does, and report what it produced. */
async function drain(source, chunk = 16000) {
  const parts = [];
  for (;;) {
    const next = await source.pull(chunk);
    if (!next.length) break;
    parts.push(next);
    if (parts.length > 10000) throw new Error("source never ended");
  }
  const total = parts.reduce((n, p) => n + p.length, 0);
  const all = new Float32Array(total);
  let at = 0;
  for (const part of parts) { all.set(part, at); at += part.length; }
  return { samples: all, chunks: parts.length };
}

test("a 16-bit mono WAV streams every sample, in order", async () => {
  const source = await wavSource(wav({ seconds: 2 }));
  assert.equal(source.seconds, 2);
  assert.equal(source.totalSamples, 32000);
  const { samples, chunks } = await drain(source);
  assert.equal(samples.length, 32000);
  assert.ok(chunks >= 2, `expected several chunks, got ${chunks}`);
  // The ramp says nothing was dropped, reordered or repeated.
  assert.ok(samples[0] < -0.99, `starts at ${samples[0]}`);
  assert.ok(samples.at(-1) > 0.99, `ends at ${samples.at(-1)}`);
  for (let i = 1; i < samples.length; i++) {
    assert.ok(samples[i] >= samples[i - 1], `sample ${i} went backwards`);
  }
});

test("every PCM width and float32 decode to the same ramp", async () => {
  for (const bits of [8, 16, 24, 32]) {
    const { samples } = await drain(await wavSource(wav({ seconds: 0.5, bits })));
    assert.equal(samples.length, 8000, `${bits}-bit length`);
    assert.ok(samples[0] < -0.9 && samples.at(-1) > 0.9, `${bits}-bit range`);
  }
  const { samples } = await drain(await wavSource(wav({ seconds: 0.5, bits: 32, float: true })));
  assert.equal(samples.length, 8000);
  assert.ok(samples[0] < -0.99 && samples.at(-1) > 0.99);
});

test("stereo is downmixed and other rates are resampled to 16 kHz", async () => {
  const stereo = await drain(await wavSource(wav({ seconds: 1, channels: 2 })));
  assert.equal(stereo.samples.length, 16000);

  for (const rate of [8000, 44100, 48000]) {
    const source = await wavSource(wav({ seconds: 1, rate }));
    assert.equal(source.seconds, 1);
    const { samples } = await drain(source);
    // Within a sample of a second's worth: the tail of a fractional ratio is
    // the only slack.
    assert.ok(Math.abs(samples.length - 16000) <= 2, `${rate} Hz gave ${samples.length}`);
    assert.ok(samples[0] < -0.9 && samples.at(-1) > 0.9, `${rate} Hz range`);
    for (let i = 1; i < samples.length; i++) {
      assert.ok(samples[i] >= samples[i - 1] - 1e-6, `${rate} Hz not monotonic at ${i}`);
    }
  }
});

test("an odd-sized chunk before the data is padded, as RIFF requires", async () => {
  const { samples } = await drain(await wavSource(wav({ seconds: 1, extraChunk: true })));
  assert.equal(samples.length, 16000);
  assert.ok(samples[0] < -0.99, "the data offset was misread");
});

test("a streamed WAV with no declared data size reads to the end", async () => {
  // Written by anything that could not seek back to fill the header in.
  for (const declared of [0, 0xffffffff]) {
    const source = await wavSource(wav({ seconds: 1, dataSize: declared }));
    const { samples } = await drain(source);
    assert.ok(Math.abs(samples.length - 16000) <= 1, `declared ${declared}`);
  }
});

test("memory does not grow with the file: one chunk is held at a time", async () => {
  // The property the whole design is for. A pull returns at most the chunk it
  // was asked for, whatever the length of the file behind it.
  for (const seconds of [1, 10, 120]) {
    const source = await wavSource(wav({ seconds }));
    const first = await source.pull(16000);
    assert.equal(first.length, 16000, `${seconds}s file gave ${first.length} samples`);
    assert.equal(source.totalSamples, seconds * 16000);
  }
});

test("what is not a WAV is handed back, not guessed at", async () => {
  assert.equal(await wavSource(new Blob([new Uint8Array(4)])), null);
  assert.equal(await wavSource(new Blob([new TextEncoder().encode("ID3\u0004junk")])), null);
  // RIFF, but not audio this can read.
  const odd = new Uint8Array(64);
  for (const [i, c] of [..."RIFF"].entries()) odd[i] = c.charCodeAt(0);
  for (const [i, c] of [..."AVI "].entries()) odd[8 + i] = c.charCodeAt(0);
  assert.equal(await wavSource(new Blob([odd])), null);
});
