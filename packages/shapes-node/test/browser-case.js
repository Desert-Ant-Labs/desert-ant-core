// Shapes' case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on shapes.tflite, with the model
// downloaded from the Hub exactly as a consumer's first page load does. It must
// return something structured-cloneable, since the harness reads it back out of
// the page. `check` then runs in Node.

export async function run({ Shapes }, { litert, litertWasmDir }) {
  const shapes = await Shapes.load({ litert, litertWasmDir });
  try {
    const circle = Array.from({ length: 65 }, (_, i) => {
      const t = (2 * Math.PI * i) / 64;
      return { x: 100 + 80 * Math.cos(t), y: 100 + 80 * Math.sin(t) };
    });
    const drag = Array.from({ length: 41 }, (_, i) => ({ x: i * 5, y: i * 2 }));
    const zigzag = [];
    for (let i = 0; i < 7; i++) {
      for (let s = 0; s < 10; s++) zigzag.push({ x: (i + s / 10) * 18, y: (i % 2 ? 80 : 0) + (s / 10) * (i % 2 ? -80 : 80) });
    }
    return {
      circle: await shapes.recognize(circle),
      line: await shapes.recognize(drag),
      zigzag: await shapes.recognize(zigzag),
      plus: await shapes.recognize([
        { points: Array.from({ length: 25 }, (_, i) => ({ x: 20 + i * (160 / 24), y: 100 })) },
        { points: Array.from({ length: 25 }, (_, i) => ({ x: 100, y: 20 + i * (160 / 24) })) },
      ]),
      degenerate: await shapes.recognize([{ x: 1, y: 1 }]),
    };
  } finally {
    shapes.dispose();
  }
}

export function check(result) {
  // The same expectations the Swift and Kotlin suites assert, so "works in the
  // browser" means the same thing it means everywhere else.
  if (result.circle?.kind !== "ellipse") {
    throw new Error(`expected an ellipse from a traced circle, got ${JSON.stringify(result.circle)}`);
  }
  if (Math.abs(result.circle.center.x - 100) > 4 || Math.abs(result.circle.semiMajor - 80) > 4) {
    throw new Error(`ellipse geometry is off: ${JSON.stringify(result.circle)}`);
  }
  if (result.line?.kind !== "line") {
    throw new Error(`expected a line from a straight drag, got ${JSON.stringify(result.line)}`);
  }
  if (result.zigzag?.kind !== "zigzag" || !(result.zigzag.teeth > 0)) {
    throw new Error(`expected a zigzag, got ${JSON.stringify(result.zigzag)}`);
  }
  if (result.plus?.kind !== "plus") {
    throw new Error(`expected a plus from two strokes, got ${JSON.stringify(result.plus)}`);
  }
  if (result.degenerate !== null) {
    throw new Error(`expected null for a one-point stroke, got ${JSON.stringify(result.degenerate)}`);
  }
}
