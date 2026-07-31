// Pure-JS WAV decode + mono mixdown + linear resample: the browser-safe
// counterpart of Swift AudioIO's portable WAV path (Sources/AudioIO/WAV.swift)
// and Kotlin's resampler. Node uses this to decode audio without a native codec
// (WAV only, matching the Swift portable path); the browser uses Web Audio
// instead (audio.js), so this stays codec-free and dependency-free.

/** Decode a WAV/RIFF Uint8Array to { samples: Float32Array (interleaved),
 *  sampleRate, channels }. Supports PCM 8/16/24/32-bit and IEEE float 32/64. */
export function decodeWav(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (o) => String.fromCharCode(bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]);
  if (bytes.length < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") {
    throw new Error("not a RIFF/WAVE file");
  }
  let format = 1, channels = 1, sampleRate = 0, bits = 16;
  let dataStart = -1, dataSize = 0;
  let pos = 12;
  while (pos + 8 <= bytes.length) {
    const id = tag(pos);
    const size = dv.getUint32(pos + 4, true);
    const body = pos + 8;
    if (id === "fmt ") {
      format = dv.getUint16(body, true);
      channels = Math.max(1, dv.getUint16(body + 2, true));
      sampleRate = dv.getUint32(body + 4, true);
      bits = dv.getUint16(body + 14, true);
      if (format === 0xfffe && body + 26 <= bytes.length) format = dv.getUint16(body + 24, true);
    } else if (id === "data") {
      dataStart = body;
      dataSize = Math.min(size, bytes.length - body);
    }
    pos = body + size + (size & 1);
  }
  if (dataStart < 0 || sampleRate <= 0) throw new Error("no data/fmt chunk");

  const bytesPer = bits / 8;
  const count = Math.floor(dataSize / bytesPer);
  const out = new Float32Array(count);
  if (format === 3) {
    if (bits === 32) for (let i = 0; i < count; i++) out[i] = dv.getFloat32(dataStart + i * 4, true);
    else if (bits === 64) for (let i = 0; i < count; i++) out[i] = dv.getFloat64(dataStart + i * 8, true);
    else throw new Error(`float ${bits}-bit unsupported`);
  } else if (format === 1) {
    if (bits === 8) for (let i = 0; i < count; i++) out[i] = (bytes[dataStart + i] - 128) / 128;
    else if (bits === 16) for (let i = 0; i < count; i++) out[i] = dv.getInt16(dataStart + i * 2, true) / 32768;
    else if (bits === 24)
      for (let i = 0; i < count; i++) {
        const o = dataStart + i * 3;
        let v = bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16);
        if (v & 0x800000) v |= ~0xffffff;
        out[i] = v / 8388608;
      }
    else if (bits === 32) for (let i = 0; i < count; i++) out[i] = dv.getInt32(dataStart + i * 4, true) / 2147483648;
    else throw new Error(`PCM ${bits}-bit unsupported`);
  } else {
    throw new Error(`format tag ${format} unsupported`);
  }
  return { samples: out, sampleRate, channels };
}

/** Average interleaved channels down to a mono Float32Array. */
export function mixdownMono(interleaved, channels) {
  if (channels <= 1) return interleaved;
  const frames = Math.floor(interleaved.length / channels);
  const out = new Float32Array(frames);
  const inv = 1 / channels;
  for (let f = 0; f < frames; f++) {
    let acc = 0;
    const base = f * channels;
    for (let c = 0; c < channels; c++) acc += interleaved[base + c];
    out[f] = acc * inv;
  }
  return out;
}

/** Linearly resample mono `x` from `from` Hz to `to` Hz. */
export function resampleLinear(x, from, to) {
  if (from <= 0 || to <= 0 || from === to || x.length < 2) return x;
  const outCount = Math.round(x.length * (to / from));
  if (outCount <= 0) return new Float32Array(0);
  const out = new Float32Array(outCount);
  const step = from / to;
  for (let i = 0; i < outCount; i++) {
    const src = i * step;
    const i0 = Math.floor(src);
    if (i0 >= x.length - 1) { out[i] = x[x.length - 1]; continue; }
    const frac = src - i0;
    out[i] = x[i0] * (1 - frac) + x[i0 + 1] * frac;
  }
  return out;
}
