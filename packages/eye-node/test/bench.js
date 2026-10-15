// Images per second through the public API, the cases of Tests/EyeTests/ThroughputTests.swift:
// the reference photo and a 12 MP upscale of it, every part and the photo part, one call at a
// time and four in flight. Runs in Node and in the browser.

/** Nearest-neighbour upscale to `width`, RGB. */
export function upscaled({ data, width: w, height: h }, width) {
  const height = Math.floor((width * h) / w);
  const c = data.length / (w * h);
  const out = new Uint8Array(width * height * 3);
  for (let y = 0; y < height; y++) {
    const sy = Math.floor((y * h) / height);
    for (let x = 0; x < width; x++) {
      const s = (sy * w + Math.floor((x * w) / width)) * c, d = (y * width + x) * 3;
      out[d] = data[s]; out[d + 1] = data[s + 1]; out[d + 2] = data[s + 2];
    }
  }
  return { data: out, width, height };
}

export async function bench(eye, fixture, { n = 30 } = {}) {
  const now = () => performance.now();
  const rows = {};
  let t = now();
  await eye.analyze(fixture);
  rows.first_ms = Math.round(now() - t);
  for (const [name, image] of [["fixture", fixture], ["12mp", upscaled(fixture, 4032)]]) {
    for (const [partName, parts] of [["all", undefined], ["photo", ["photo"]]]) {
      const opts = parts ? { parts } : undefined;
      for (let i = 0; i < 2; i++) await eye.analyze(image, opts);
      t = now();
      for (let i = 0; i < n; i++) await eye.analyze(image, opts);
      const serial = (n * 1000) / (now() - t);
      t = now();
      let next = 0;
      const worker = async () => { while (next++ < n) await eye.analyze(image, opts); };
      await Promise.all([worker(), worker(), worker(), worker()]);
      const parallel4 = (n * 1000) / (now() - t);
      rows[`${name}_${partName}`] = { serial: +serial.toFixed(2), parallel4: +parallel4.toFixed(2) };
    }
  }
  return rows;
}
