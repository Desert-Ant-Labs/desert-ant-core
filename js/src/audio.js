// Browser audio-decode host for the wasm AudioIO backend. Web Audio decodes any
// container the browser supports (wav/mp3/m4a/ogg/...), and an
// OfflineAudioContext renders it to mono at the requested sample rate (it
// downmixes and resamples for us). Installs the `__DalAudioHost.decode` global
// that Swift AudioIO calls on wasm; browser-safe (no `node:*`).

/**
 * Install `globalThis.__DalAudioHost.decode(path, bytes, sampleRate)`, returning
 * a mono `Float32Array` at `sampleRate`. In the browser `path` is null and
 * `bytes` is the file's `Uint8Array`. Idempotent.
 */
export function installAudioHost() {
  globalThis.__DalAudioHost ??= {
    decode: async (path, bytes, sampleRate) => decodeBrowser(bytes, sampleRate),
  };
  return globalThis.__DalAudioHost;
}

async function decodeBrowser(bytes, sampleRate) {
  if (!bytes) throw new Error("__DalAudioHost.decode: browser decode needs file bytes");
  const Offline = globalThis.OfflineAudioContext || globalThis.webkitOfflineAudioContext;
  if (!Offline) throw new Error("__DalAudioHost.decode: no OfflineAudioContext");

  // decodeAudioData consumes (detaches) its ArrayBuffer, so it needs one the
  // caller is not going to reuse. A view that covers its whole buffer already
  // is one: callers here build it from `blob.arrayBuffer()` and drop it.
  //
  // Copying unconditionally is what this used to do, and on a large file it is
  // the difference between working and not: a 1.8 GB video became 3.6 GB before
  // the decoder started, on top of the 675 MB it decodes into, and
  // decodeAudioData answers memory pressure by returning a SHORT buffer with no
  // error rather than failing.
  const whole = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength;
  const ab = whole ? bytes.buffer : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const probe = new Offline(1, 1, 44100);
  const decoded = await probe.decodeAudioData(ab);

  // Render through a 1-channel OfflineAudioContext at the target rate: it mixes
  // down to mono and resamples in one pass.
  const frames = Math.max(1, Math.round(decoded.duration * sampleRate));
  const ctx = new Offline(1, frames, sampleRate);
  const src = ctx.createBufferSource();
  src.buffer = decoded;
  src.connect(ctx.destination);
  src.start();
  const rendered = await ctx.startRendering();
  return rendered.getChannelData(0);
}
