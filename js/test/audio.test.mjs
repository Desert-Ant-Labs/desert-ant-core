import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeWav, mixdownMono, resampleLinear } from "../index.js";
import { installAudioHost } from "../node.js";

// Build a minimal 16-bit PCM WAV in JS (mirror of Swift WAV.encode) so the test
// needs no fixture file.
function encodeWav(samples, sampleRate, channels = 1) {
  const dataSize = samples.length * 2;
  const buf = new ArrayBuffer(44 + dataSize);
  const dv = new DataView(buf);
  const tag = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
  tag(0, "RIFF"); dv.setUint32(4, 36 + dataSize, true); tag(8, "WAVE");
  tag(12, "fmt "); dv.setUint32(16, 16, true); dv.setUint16(20, 1, true);
  dv.setUint16(22, channels, true); dv.setUint32(24, sampleRate, true);
  dv.setUint32(28, sampleRate * channels * 2, true); dv.setUint16(32, channels * 2, true);
  dv.setUint16(34, 16, true); tag(36, "data"); dv.setUint32(40, dataSize, true);
  for (let i = 0; i < samples.length; i++) {
    const v = Math.max(-1, Math.min(1, samples[i]));
    dv.setInt16(44 + i * 2, Math.round(v * 32767), true);
  }
  return new Uint8Array(buf);
}

const tone = (n, freq = 440, sr = 16000) =>
  Float32Array.from({ length: n }, (_, i) => 0.5 * Math.sin((2 * Math.PI * freq * i) / sr));

test("decodeWav round-trips 16-bit PCM within quantization error", () => {
  const x = tone(2000);
  const { samples, sampleRate, channels } = decodeWav(encodeWav(x, 16000, 1));
  assert.equal(sampleRate, 16000);
  assert.equal(channels, 1);
  assert.equal(samples.length, x.length);
  let maxErr = 0;
  for (let i = 0; i < x.length; i++) maxErr = Math.max(maxErr, Math.abs(x[i] - samples[i]));
  assert.ok(maxErr < 1e-3, `maxErr ${maxErr}`);
});

test("stereo mixdown averages channels", () => {
  const interleaved = Float32Array.from({ length: 200 }, (_, i) => (i % 2 === 0 ? 0.5 : -0.5));
  const mono = mixdownMono(interleaved, 2);
  assert.equal(mono.length, 100);
  assert.ok(mono.every((v) => Math.abs(v) < 1e-6));
});

test("resampleLinear roughly doubles length from 8k to 16k", () => {
  const y = resampleLinear(tone(800, 440, 8000), 8000, 16000);
  assert.ok(Math.abs(y.length - 1600) <= 4, `len ${y.length}`);
});

test("installAudioHost decodes bytes to mono at the target rate (node)", async () => {
  const host = installAudioHost();
  const wav = encodeWav(tone(1600, 440, 8000), 8000, 1);
  const mono = await host.decode(null, wav, 16000);
  assert.ok(mono instanceof Float32Array);
  assert.ok(Math.abs(mono.length - 3200) <= 8, `len ${mono.length}`); // 1600 @ 8k -> ~3200 @ 16k
});
