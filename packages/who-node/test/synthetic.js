// Speech-shaped noise, the Swift smoke suite's signal (Tests/WhoTests/SmokeTests.swift):
// syllables at 4 Hz under two alternating spectral tilts. Deterministic, so the
// browser case and the Node suite hear the same recording.
export function audio(seconds, sampleRate = 16000) {
  const samples = new Float32Array(sampleRate * seconds);
  let state = 0x9e3779b9;
  const random = () => {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state / 0x100000000 - 0.5;
  };
  for (let n = 0; n < samples.length; n++) {
    const t = n / sampleRate;
    const syllable = 0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * t);
    const tilt = Math.floor(t / 5) % 2 === 0 ? 1 : 0.3;
    samples[n] = syllable * tilt * 0.6 * random();
  }
  return samples;
}

/** The samples as a 16-bit mono WAV file. */
export function wav(samples, sampleRate) {
  const bytes = new Uint8Array(44 + samples.length * 2);
  const view = new DataView(bytes.buffer);
  const ascii = (at, s) => { for (let i = 0; i < s.length; i++) bytes[at + i] = s.charCodeAt(i); };
  ascii(0, "RIFF"); view.setUint32(4, 36 + samples.length * 2, true); ascii(8, "WAVE");
  ascii(12, "fmt "); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true); view.setUint32(28, sampleRate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  ascii(36, "data"); view.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) {
    view.setInt16(44 + i * 2, Math.max(-32768, Math.min(32767, Math.round(samples[i] * 32767))), true);
  }
  return bytes;
}
