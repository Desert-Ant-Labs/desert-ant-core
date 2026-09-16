// Voz's browser runtime: the ONNX Runtime Web half of the wasm core.
//
// `Sources/Voz/Pipeline.swift` compiled to wasm owns the windowing, the
// lane-batched decode and the splice, and calls out here only to run a model.
// The contract is `Sources/Voz/Engine+Wasm.swift`: one object on
// `globalThis.__vozHost` with `run(model, inputs)`, where `model` is "mel",
// "encoder" or "decoder". Deliberately not the shared `dalModelHost` seam,
// which carries one session per module; Voz runs three.
//
// Browser-safe: no `node:*` imports.

const ortStateKey = Symbol.for("ai.desertant.voz.ort");
const ortState = (globalThis[ortStateKey] ??= {});

async function importOrt(packageName) {
  try {
    return await import("onnxruntime-web/all");
  } catch (cause) {
    const missing =
      cause?.code === "ERR_MODULE_NOT_FOUND" ||
      cause?.code === "MODULE_NOT_FOUND" ||
      String(cause?.message ?? "").includes("onnxruntime-web");
    if (!missing) throw cause;
    throw new Error(
      `${packageName} browser runtime requires onnxruntime-web. ` +
        `Install it with: npm i ${packageName} onnxruntime-web. ` +
        `If you already bundle it yourself, pass it to load({ ort }).`,
      { cause },
    );
  }
}

/**
 * Load onnxruntime-web and apply the settings this model needs. Once per page.
 *
 * `numThreads = 1` is not a default worth inheriting, it is a measurement. Every
 * model here runs on the GPU or the Neural Engine, so the wasm threads only ever
 * carry the few shape operators the runtime keeps on the CPU: on Chromium it is
 * 46.6 RTFx either way. In Safari it is not. WebKit has no JSPI, so the runtime
 * loads its 28 MB asyncify-instrumented build and WebKit's optimising JIT tiers
 * that module up on every thread at once, taking CPU to 759% of eight cores. The
 * decode step is dispatch-bound and pays for the starvation directly: a second
 * pass over the same audio fell from 23.3 RTFx to 20.0. At one thread it does
 * not. Upstream is onnxruntime#26827.
 *
 * It also means the page needs no SharedArrayBuffer, and so does not have to be
 * cross-origin isolated to run at full speed.
 *
 * @param {object} o
 * @param {any} [o.ort] caller-injected module (tests, custom builds)
 * @param {string} [o.wasmDir] where the runtime's own .wasm files live
 * @param {string} o.packageName consumer package name for the install hint
 */
export async function loadOrt({ ort, wasmDir, packageName }) {
  const rt = ort ?? ortState.module ?? (await importOrt(packageName));
  ortState.module = rt;
  if (wasmDir) rt.env.wasm.wasmPaths = wasmDir;
  rt.env.wasm.numThreads = 1;
  rt.env.logLevel = "error";
  return rt;
}

/**
 * Expand a packed weight blob into the bytes the graph's external data expects.
 *
 * The encoder ships as 4-bit groups of 32 because that is the only way the
 * bundle meets its size target, 334 MB against 1187. It is not a quantized
 * model: ONNX Runtime's 4-bit matmul is written for the single-row case LLM
 * decoding has and runs 3.2x slower on this encoder's 188 rows. So the small
 * form is for the wire only. It is expanded once, here, and every matmul
 * afterwards is the float16 kernel.
 *
 * Requires `Float16Array`. Without it this throws rather than degrading, which
 * is the intent: a silent float32 fallback would double the resident weights.
 *
 * @param {ArrayBuffer} blob packed bytes, `meta.encoder_packed.blob`
 * @param {object} packed `encoder_packed` from meta.json
 * @returns {Uint8Array} laid out exactly as the unpacked weights file
 */
export function expand(blob, packed) {
  const source = new Uint8Array(blob);
  const out = new Uint8Array(packed.bytes);
  const wide = new Float16Array(out.buffer);
  const group = packed.group;
  let at = 0;
  for (const run of packed.runs) {
    if (!run.packed) {
      out.set(source.subarray(at, at + run.bytes), run.at);
      at += run.bytes;
      continue;
    }
    const count = run.bytes / 2;
    const scales = new Float16Array(source.buffer, source.byteOffset + at, Math.ceil(count / group));
    at += scales.byteLength;
    const nibbles = source.subarray(at, at + Math.ceil(count / 2));
    at += nibbles.byteLength;
    const base = run.at / 2;
    for (let i = 0; i < count; i++) {
      const byte = nibbles[i >> 1];
      const nibble = i & 1 ? byte >> 4 : byte & 15;
      wide[base + i] = (nibble - 8) * scales[(i / group) | 0];
    }
  }
  return out;
}

/**
 * Which decode step this browser should load, and how many lanes it has.
 *
 * The choice is genuinely two-sided, which is why the bundle ships two. WebNN
 * runs the step on the Neural Engine, where it is throughput-bound and narrow
 * lanes win. A browser with only WebGPU is dispatch-bound, and the same work
 * wants fewer, wider steps: at 48 lanes a ten-minute file is one group instead
 * of three. Worth 13.0 RTFx to 23.7 in Safari, and 1.2 the other way on WebNN.
 *
 * @param {object} meta the bundle manifest
 * @param {boolean} webnn whether the decode step will run on WebNN
 */
export function decodeStepFor(meta, webnn) {
  const fallback = !webnn ? meta.webgpu_decoder : null;
  return {
    file: fallback?.file ?? "decoder.onnx",
    lanes: fallback?.decode_lanes ?? meta.decode_lanes,
  };
}

/** Whether this browser exposes WebNN, which only Chromium does today. */
export function hasWebNN() {
  return typeof navigator !== "undefined" && typeof navigator.ml !== "undefined";
}

/**
 * Fetch a bundle's files, keyed by name. `meta.json` is read first because it
 * names the other two: which decode step to take, and the packed weight blob.
 *
 * @param {string} baseUrl ends in "/"
 * @param {object} [o]
 * @param {boolean} [o.webnn] override the WebNN detection
 */
export async function fetchVozBundle(baseUrl, { webnn = hasWebNN() } = {}) {
  const get = async (name) => {
    const response = await fetch(new URL(name, baseUrl).toString());
    if (!response.ok) throw new Error(`voz: ${name} -> HTTP ${response.status}`);
    return response;
  };
  const meta = await (await get("meta.json")).json();
  const step = decodeStepFor(meta, webnn);
  // encoder.weights is deliberately absent. When the bundle is packed the
  // weights come from encoder.q4 and are expanded at load; when it is not, the
  // graph carries them inline.
  const names = ["vocab.json", "embedding.f16", "encoder.onnx", step.file];
  if (meta.encoder_packed) names.push(meta.encoder_packed.blob);
  const parts = await Promise.all(
    names.map(async (name) => [
      name,
      name.endsWith(".json") ? await (await get(name)).json() : await (await get(name)).arrayBuffer(),
    ]),
  );
  // The core is handed this manifest verbatim, so it has to describe the decode
  // step that was actually loaded rather than the one the export defaulted to.
  meta.decode_lanes = step.lanes;
  return { meta, step, files: Object.fromEntries(parts) };
}

/**
 * The ONNX Runtime Web implementation of the `__vozHost` contract.
 *
 * Two placement decisions are measured rather than assumed. The encoder runs on
 * WebGPU: WebNN leaves two thirds of it to the CPU, coming back in 71
 * partitions. The decode step runs on WebNN where the browser has it, because
 * WebNN takes its whole graph and on macOS is Core ML underneath, which is worth
 * 36.0 RTFx to 39.4. `deviceType` is advisory; npu, gpu and cpu measured
 * identical, because Core ML places the graph itself.
 */
export function makeVozHost({ ort, sessions }) {
  const calls = { mel: 0, encoder: 0, decoder: 0 };
  const millis = { mel: 0, encoder: 0, decoder: 0 };

  const run = async (model, inputs) => {
    const session = sessions[model];
    if (!session) throw new Error(`voz: no session for "${model}"`);
    const started = performance.now();
    const feeds = {};
    for (const name of session.inputNames) {
      const tensor = inputs[name];
      if (!tensor) throw new Error(`voz: ${model} wants "${name}" and it was not supplied`);
      feeds[name] = new ort.Tensor(tensor.type, tensor.data, tensor.dims);
    }
    const results = await session.run(feeds);
    const outputs = {};
    for (const name of session.outputNames) {
      const tensor = results[name];
      outputs[name] = { data: tensor.data, dims: tensor.dims, type: tensor.type };
    }
    calls[model]++;
    millis[model] += performance.now() - started;
    return outputs;
  };

  return {
    host: { run },
    /** Install as the object `Sources/Voz/Engine+Wasm.swift` looks for. */
    install(target = globalThis) {
      target.__vozHost = { run };
      return this;
    },
    /** Per-model call counts and wall time, for attributing a slow run. */
    get timings() {
      return { calls: { ...calls }, millis: { ...millis } };
    },
    /** Zero them, so a second transcript is not read through the first. */
    resetTimings() {
      for (const key of Object.keys(calls)) {
        calls[key] = 0;
        millis[key] = 0;
      }
    },
  };
}

/**
 * Compile a bundle's graphs into sessions.
 *
 * Graph optimization is off deliberately. ONNX Runtime's MatMul+Add fusion emits
 * Gemm, whose WebGPU kernel is a naive one, and on this encoder that costs more
 * than every fusion gains. Measured three times across two graph shapes:
 * "disabled" equals "basic", and "extended" is worse.
 *
 * @param {object} o
 * @param {any} o.ort
 * @param {Record<string, ArrayBuffer>} o.models graphs by model name
 * @param {Record<string, object>} [o.weights] external data by model name
 * @param {Record<string, any[]>} [o.providers] execution providers by model name
 * @param {() => void} [o.onLoaded] called once every session exists
 */
export async function createVozSessions({
  ort,
  models,
  weights = {},
  providers = {},
  ep = "webgpu",
  onLoaded,
}) {
  const base = { executionProviders: [ep], graphOptimizationLevel: "disabled" };
  const sessions = {};
  for (const [name, bytes] of Object.entries(models)) {
    const external = weights[name];
    const options = providers[name] ? { ...base, executionProviders: providers[name] } : base;
    sessions[name] = await ort.InferenceSession.create(
      new Uint8Array(bytes),
      external ? { ...options, externalData: [external] } : options,
    );
  }
  // The caller's copy of any external weights is dead once every session has
  // been created. Releasing it before anything else allocates matters: it is
  // 1.19 GB, and holding it costs a page that much on top of the copy the
  // runtime has already uploaded to the GPU.
  onLoaded?.();
  return sessions;
}

/**
 * Fetch a bundle, compile it, and install the host the wasm core looks for.
 *
 * @param {object} o
 * @param {string} o.baseUrl where the bundle's files are served from
 * @param {any} [o.ort] caller-injected onnxruntime-web
 * @param {string} [o.wasmDir] where the runtime's own .wasm files live
 * @param {string} [o.packageName] consumer package name for the install hint
 * @param {boolean} [o.webnn] override the WebNN detection
 * @returns the host, the manifest, and the sidecars the core needs at load
 */
export async function loadVoz({
  baseUrl,
  ort: injected,
  wasmDir,
  packageName = "@desert-ant-labs/voz",
  webnn = hasWebNN(),
}) {
  const ort = await loadOrt({ ort: injected, wasmDir, packageName });
  const { meta, step, files } = await fetchVozBundle(baseUrl, { webnn });

  const weights = {};
  if (meta.encoder_packed) {
    weights.encoder = {
      path: meta.encoder_packed.target,
      data: expand(files[meta.encoder_packed.blob], meta.encoder_packed),
    };
  }

  const sessions = await createVozSessions({
    ort,
    models: { encoder: files["encoder.onnx"], decoder: files[step.file] },
    weights,
    providers: webnn ? { decoder: [{ name: "webnn", deviceType: "npu" }] } : {},
    onLoaded: () => {
      delete weights.encoder;
      delete files[meta.encoder_packed?.blob];
    },
  });

  return {
    host: makeVozHost({ ort, sessions }).install(),
    meta,
    vocab: files["vocab.json"],
    embedding: files["embedding.f16"],
  };
}
