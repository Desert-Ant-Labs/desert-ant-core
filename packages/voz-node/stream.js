// Turning a file into mono 16 kHz samples a chunk at a time, so that memory
// does not grow with the length of the recording.
//
// The core already works this way: it asks for audio when it needs it and frees
// what is behind the window it is transcribing. What used to undo that is this
// side, where a whole file became a whole decoded buffer became a whole
// Float32Array: a 29-minute video peaked around 2.7 GB, of which 2.5 GB was the
// file and its decoded form rather than anything the model needed.
//
// Three sources, in order of preference:
//
//   * WAV is framed so simply that a Blob slice is a valid chunk, so it streams
//     with no dependency at all.
//   * Anything else streams through mediabunny, which demuxes the container and
//     decodes it with WebCodecs, reading from the Blob as it goes. A real
//     dependency rather than something the caller passes: constant memory for
//     any file is the promise, and a promise kept only by callers who installed
//     an optional extra is not one. Imported lazily, so it is a 179 KB chunk
//     that a caller who only ever hands over WAV or samples never downloads.
//   * Failing both, `decodeAudioData` on the whole file, which is what this
//     used to always do and is the path that costs memory.
//
// Measured on a 29-minute recording, peak resident: 2.7 GB whole-file against
// 2.5 GB streaming, where 2.5 GB is the model and the runtime. Streaming is
// flat with length - a one-minute file peaks the same as a 29-minute one -
// which is the property that matters, because the alternative grows without
// bound and a 1.8 GB video reached 7.7 GB.

/** Samples per chunk. Four seconds at 16 kHz: big enough that the per-call cost
 *  disappears, small enough that it is noise next to one 15-second window. */
const CHUNK = 16000 * 4;

// Each pull returns a fresh array rather than a reused buffer. Reuse was tried
// and is not available: the core takes the samples as a JavaScript typed array,
// and JavaScriptKit reads a view of a larger buffer as though it owned the whole
// thing, which is a wasm "memory access out of bounds" rather than a wrong
// answer. The garbage is a chunk at a time and the collector keeps up.

/** Mono 16 kHz, which is what the frontend takes. */
const RATE = 16000;

/**
 * A streaming source for a WAV Blob or File.
 *
 * Reads the header, then hands back samples from `Blob.slice()`, which the
 * browser serves from disk rather than from memory. Resident cost is one chunk.
 *
 * @returns {Promise<{ seconds: number, totalSamples: number, pull: (count: number) => Promise<Float32Array> }|null>}
 *   null when the file is not a WAV this can read, so the caller can fall back.
 */
export async function wavSource(blob) {
  // 64 KB covers RIFF plus any sane chunk layout before `data`.
  const head = new Uint8Array(await blob.slice(0, Math.min(65536, blob.size)).arrayBuffer());
  const layout = parseWavHeader(head, blob.size);
  if (!layout) return null;

  const { dataStart, dataSize, channels, sampleRate, bits, float } = layout;
  const bytesPerFrame = channels * (bits / 8);
  const frames = Math.floor(dataSize / bytesPerFrame);
  const seconds = frames / sampleRate;
  // The ratio is applied by picking source frames per output sample, so a rate
  // that is not a multiple of 16 kHz resamples the same way the portable path
  // does: linear, nearest-neighbour at the edges.
  const ratio = sampleRate / RATE;
  let outputAt = 0;

  return {
    seconds,
    totalSamples: Math.floor(frames / ratio),
    async pull(count) {
      const wanted = Math.min(count || CHUNK, CHUNK);
      const firstFrame = Math.floor(outputAt * ratio);
      if (firstFrame >= frames) return new Float32Array(0);
      const lastFrame = Math.min(frames, Math.ceil((outputAt + wanted) * ratio) + 1);
      const from = dataStart + firstFrame * bytesPerFrame;
      const to = dataStart + lastFrame * bytesPerFrame;
      const raw = new Uint8Array(await blob.slice(from, to).arrayBuffer());
      const source = readFrames(raw, lastFrame - firstFrame, channels, bits, float);

      const out = new Float32Array(Math.max(0, Math.min(
        wanted, Math.floor(frames / ratio) - outputAt)));
      for (let i = 0; i < out.length; i++) {
        const at = (outputAt + i) * ratio - firstFrame;
        const low = Math.floor(at);
        const high = Math.min(low + 1, source.length - 1);
        if (low >= source.length) { out[i] = source[source.length - 1] ?? 0; continue; }
        out[i] = source[low] + (source[high] - source[low]) * (at - low);
      }
      outputAt += out.length;
      return out;
    },
  };
}

/**
 * A streaming source for any container mediabunny can read, decoded with
 * WebCodecs. Returns null for a file it cannot decode, so the caller falls
 * back to decoding the whole thing.
 *
 * Mono 16 kHz comes out of a small resampling loop rather than Web Audio,
 * because an OfflineAudioContext renders a whole buffer and that is the thing
 * being avoided. Linear interpolation, matching the WAV path above and the
 * portable path in the core.
 */
export async function mediaSource(blob) {
  const { Input, ALL_FORMATS, BlobSource, AudioSampleSink } = await import("mediabunny");
  const input = new Input({ formats: ALL_FORMATS, source: new BlobSource(blob) });
  const track = await input.getPrimaryAudioTrack();
  if (!track || !(await track.canDecode())) return null;

  const seconds = await input.computeDuration();
  const sink = new AudioSampleSink(track);
  const samples = sink.samples()[Symbol.asyncIterator]();

  // One decoded sample at a time, resampled into a queue the pulls drain.
  let queue = new Float32Array(0);
  let carry = 0;                                  // fractional read position
  let done = false;

  const take = (count) => {
    const out = new Float32Array(count);
    out.set(queue.subarray(0, count));
    // A fresh array rather than a subarray: a subarray keeps the whole buffer
    // it came from alive, so the queue would never shrink back.
    queue = Float32Array.from(queue.subarray(count));
    return out;
  };

  return {
    seconds,
    totalSamples: Math.round(seconds * RATE),
    async pull(count) {
      const wanted = Math.min(count || CHUNK, CHUNK);
      while (queue.length < wanted && !done) {
        const { value: sample, done: finished } = await samples.next();
        if (finished || !sample) { done = true; break; }
        try {
          const frames = sample.numberOfFrames;
          const channels = sample.numberOfChannels;
          const planar = new Float32Array(frames * channels);
          sample.copyTo(planar, { format: "f32-planar", planeIndex: 0 });
          let mono = planar.subarray(0, frames);
          if (channels > 1) {
            // Sum the planes rather than taking one: a stereo file with the
            // voice panned would otherwise lose it.
            mono = Float32Array.from(mono);
            for (let channel = 1; channel < channels; channel++) {
              const plane = new Float32Array(frames);
              sample.copyTo(plane, { format: "f32-planar", planeIndex: channel });
              for (let i = 0; i < frames; i++) mono[i] += plane[i];
            }
            for (let i = 0; i < frames; i++) mono[i] /= channels;
          }
          queue = concat(queue, resample(mono, sample.sampleRate, RATE, carry));
          carry = (carry + mono.length * RATE / sample.sampleRate) % 1;
        } finally {
          sample.close();
        }
      }
      return take(Math.min(wanted, queue.length));
    },
  };
}

function concat(a, b) {
  if (!a.length) return b;
  if (!b.length) return a;
  const out = new Float32Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/** Linear resample, continuing from `carry` so chunk boundaries do not click. */
function resample(samples, from, to, carry = 0) {
  if (from === to) return samples;
  const ratio = from / to;
  const out = new Float32Array(Math.max(0, Math.floor((samples.length - carry) / ratio)));
  for (let i = 0; i < out.length; i++) {
    const at = carry + i * ratio;
    const low = Math.floor(at);
    const high = Math.min(low + 1, samples.length - 1);
    out[i] = samples[low] + (samples[high] - samples[low]) * (at - low);
  }
  return out;
}

/** Header fields, or null if this is not a WAV we can read. */
function parseWavHeader(head, size) {
  if (head.length < 12) return null;
  const tag = (o) => String.fromCharCode(head[o], head[o + 1], head[o + 2], head[o + 3]);
  if (tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;
  const dv = new DataView(head.buffer, head.byteOffset, head.byteLength);

  let format = 1, channels = 1, sampleRate = 0, bits = 16;
  let dataStart = -1, dataSize = 0;
  let pos = 12;
  while (pos + 8 <= head.length) {
    const id = tag(pos);
    const chunkSize = dv.getUint32(pos + 4, true);
    const body = pos + 8;
    if (id === "fmt " && body + 16 <= head.length) {
      format = dv.getUint16(body, true);
      channels = Math.max(1, dv.getUint16(body + 2, true));
      sampleRate = dv.getUint32(body + 4, true);
      bits = dv.getUint16(body + 14, true);
      if (format === 0xfffe && body + 26 <= head.length) format = dv.getUint16(body + 24, true);
    } else if (id === "data") {
      dataStart = body;
      // A streamed WAV can carry 0xffffffff or 0 here, meaning "to the end".
      dataSize = chunkSize > 0 && chunkSize < size - body ? chunkSize : size - body;
      break;
    }
    pos = body + chunkSize + (chunkSize & 1);
  }
  if (dataStart < 0 || sampleRate <= 0) return null;
  const float = format === 3;
  if (![1, 3].includes(format) || ![8, 16, 24, 32].includes(bits)) return null;
  if (float && bits !== 32) return null;
  return { dataStart, dataSize, channels, sampleRate, bits, float };
}

/** Interleaved PCM to mono float, downmixing by averaging channels. */
function readFrames(raw, frameCount, channels, bits, float) {
  const dv = new DataView(raw.buffer, raw.byteOffset, raw.byteLength);
  const step = bits / 8;
  const out = new Float32Array(frameCount);
  for (let frame = 0; frame < frameCount; frame++) {
    let sum = 0;
    for (let channel = 0; channel < channels; channel++) {
      const at = (frame * channels + channel) * step;
      if (at + step > raw.length) return out.subarray(0, frame);
      sum += float ? dv.getFloat32(at, true) : readInt(dv, at, bits);
    }
    out[frame] = sum / channels;
  }
  return out;
}

function readInt(dv, at, bits) {
  if (bits === 8) return (dv.getUint8(at) - 128) / 128;
  if (bits === 16) return dv.getInt16(at, true) / 32768;
  if (bits === 24) {
    const value = dv.getUint8(at) | (dv.getUint8(at + 1) << 8) | (dv.getInt8(at + 2) << 16);
    return value / 8388608;
  }
  return dv.getInt32(at, true) / 2147483648;
}
