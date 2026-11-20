// Speed in the browser (DAL_BROWSER_CASE=browser-bench.js node js/test/browser/run.mjs --only face): the cases of
// Tests/FaceTests/BenchTests.swift, median milliseconds per photo for FaceDetector and Face, on LiteRT.js's wasm
// and WebGPU.
const RESOURCES = "/Tests/FaceTests/Resources/";

async function photo(name) {
  const b = new Uint8Array(await (await fetch(`${RESOURCES}${name}.rgb`)).arrayBuffer());
  const v = new DataView(b.buffer);
  const width = v.getUint32(0, true), height = v.getUint32(4, true);
  return { data: b.subarray(8, 8 + width * height * 3), width, height };
}

function scaled({ data, width: w, height: h }, width) {
  const height = Math.floor((width * h) / w);
  const out = new Uint8Array(width * height * 3);
  for (let y = 0; y < height; y++) {
    const sy = Math.floor((y * h) / height);
    for (let x = 0; x < width; x++) {
      const s = (sy * w + Math.floor((x * w) / width)) * 3, d = (y * width + x) * 3;
      out[d] = data[s]; out[d + 1] = data[s + 1]; out[d + 2] = data[s + 2];
    }
  }
  return { data: out, width, height };
}

async function median(n, body) {
  for (let i = 0; i < 2; i++) await body();
  const times = [];
  for (let i = 0; i < n; i++) {
    const t = performance.now();
    await body();
    times.push(performance.now() - t);
  }
  return +times.sort((a, b) => a - b)[Math.floor(n / 2)].toFixed(1);
}

// The Swift benchmark's library: 5,000 photos of 4 faces, faceprints around 500 people.
function faceprints(Faceprint) {
  let s = 7;
  const rand = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32) - 0.5;
  return (k, i) => {
    const v = new Float32Array(128);
    v[((k * 4 + i) % 500) % 128] = 1;
    for (let j = 0; j < 128; j++) v[j] += rand() * 0.6 * Math.sqrt(12 / 128);
    return { box: { x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3 }, landmarks: [], confidence: 0.9, faceprint: new Faceprint(v) };
  };
}

export async function run({ Face, FaceDetector, Faceprint }, { litert, litertWasmDir }) {
  const small = await photo("group");
  const images = [["photo", small], ["12mp", scaled(small, 5070)]];
  const out = { userAgent: navigator.userAgent, threads: self.crossOriginIsolated === true };
  for (const accelerator of ["wasm", "webgpu"]) {
    try {
      const face = await Face.load({ litert, litertWasmDir, accelerator });
      const detector = await FaceDetector.load({ litert, litertWasmDir, accelerator });
      const rows = {};
      for (const [name, image] of images) {
        rows[`detector_${name}_ms`] = await median(10, () => detector.faces(image));
        rows[`face_${name}_ms`] = await median(10, () => face.faces(image));
      }
      if (accelerator === "webgpu") {
        const library = await face.library();
        const make = faceprints(Faceprint);
        const t = performance.now();
        for (let k = 0; k < 5000; k++) await library.add([0, 1, 2, 3].map((i) => make(k, i)), `img${k}`);
        await library.regroup();
        rows.library_20000_s = +((performance.now() - t) / 1000).toFixed(2);
        rows.library_people = (await library.people()).length;
        await library.close();
      }
      out[accelerator] = rows;
      face.dispose();
      detector.dispose();
    } catch (e) {
      out[accelerator] = { error: String(e).slice(0, 200) };
    }
  }
  return out;
}

export function check(r) {
  console.log("FACE_BENCH " + JSON.stringify(r));
}
