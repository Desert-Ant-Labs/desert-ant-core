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

/**
 * Apply the runtime settings this model needs to a caller-supplied
 * onnxruntime-web.
 *
 * The runtime is a parameter here because this module is shared and has no
 * business choosing one: the browser wants onnxruntime-web and Node wants
 * onnxruntime-node, which is a native addon. `packages/voz-node` picks per
 * platform behind its `#platform` seam and imports the browser one on demand,
 * so a consumer installs it and calls `Voz.load()` with nothing.
 *
 *     import * as ort from "onnxruntime-web/all";
 *     const voz = await loadVoz({ baseUrl, ort });
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
 * @param {any} o.ort the onnxruntime-web module, e.g. "onnxruntime-web/all"
 * @param {string} [o.wasmDir] where the runtime's own .wasm files live
 */
export function configureOrt({ ort, wasmDir }) {
  if (!ort) {
    throw new Error(
      "voz: pass the onnxruntime-web module, e.g. " +
        'import * as ort from "onnxruntime-web/all"; loadVoz({ baseUrl, ort }). ' +
        "This layer is model-agnostic about where the runtime came from; the voz " +
        "package imports one for the browser itself.",
    );
  }
  if (wasmDir) ort.env.wasm.wasmPaths = wasmDir;
  ort.env.wasm.numThreads = 1;
  ort.env.logLevel = "error";
  return ort;
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
 * @param {ArrayBuffer|Uint8Array} blob packed bytes, `meta.encoder_packed.blob`
 * @param {object} packed `encoder_packed` from meta.json
 * @returns {Uint8Array} laid out exactly as the unpacked weights file
 */
export function expand(blob, packed) {
  // Taken as is when it is already a view: a copy here is another 334 MB
  // resident beside the 1.19 GB being written.
  const source = blob instanceof Uint8Array ? blob : new Uint8Array(blob);
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
 * Everything comes back as bytes, including the two JSON files. The wasm core
 * parses its own sidecars, so handing it a parsed object would mean stringifying
 * it back; `meta` is returned parsed *as well* because the host reads it to
 * decide what to compile.
 *
 * `fetchFile` is the seam a cache goes behind: it takes a URL and returns bytes,
 * defaulting to one `fetch`. Node reads through a disk cache, a browser through
 * the Cache API, and neither concern belongs here.
 *
 * @param {string} baseUrl ends in "/"
 * @param {object} [o]
 * @param {boolean} [o.webnn] override the WebNN detection
 * @param {(url: string, name: string) => Promise<ArrayBuffer|Uint8Array>} [o.fetchFile]
 */
export async function fetchVozBundle(baseUrl, { webnn = hasWebNN(), fetchFile } = {}) {
  const read = fetchFile ?? (async (url, name) => {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`voz: ${name} -> HTTP ${response.status}`);
    return response.arrayBuffer();
  });
  const get = async (name) => {
    const bytes = await read(new URL(name, baseUrl).toString(), name);
    return bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  };

  const metaBytes = await get("meta.json");
  const meta = JSON.parse(new TextDecoder().decode(metaBytes));
  const step = decodeStepFor(meta, webnn);
  // encoder.weights is deliberately absent. When the bundle is packed the
  // weights come from encoder.q4 and are expanded at load; when it is not, the
  // graph carries them inline.
  const names = ["vocab.json", "embedding.f16", "encoder.onnx", step.file];
  // A bundle carries its encoder weights one of two ways. `encoder_external`
  // names a file the graph refers to directly, which is what a quantized
  // encoder ships: the runtime reads it as is. `encoder_packed` is the older
  // form, float16 weights squeezed to 4 bits for the wire only and expanded
  // here before the runtime sees them.
  if (meta.encoder_external) names.push(meta.encoder_external);
  else if (meta.encoder_packed) names.push(meta.encoder_packed.blob);
  const parts = await Promise.all(names.map(async (name) => [name, await get(name)]));
  // The core is handed this manifest verbatim, so it has to describe the decode
  // step that was actually loaded rather than the one the export defaulted to.
  meta.decode_lanes = step.lanes;
  // Reserialized, not the bytes that arrived: `decode_lanes` above is the host's
  // correction and the core has to see it.
  return {
    meta,
    metaBytes: new TextEncoder().encode(JSON.stringify(meta)),
    step,
    files: Object.fromEntries(parts),
  };
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
 * `ep` is the execution provider the graphs compile for. WebGPU is the point of
 * this runtime, but the encoder's shaders need `shader-f16`, and a browser
 * whose adapter lacks it - a software adapter, which is what a machine with no
 * GPU exposes - fails to create the session at all rather than running slowly.
 * "wasm" runs the same graphs on the CPU, which is what makes an inference test
 * possible on a runner without a GPU.
 *
 * Graph optimization is off deliberately. ONNX Runtime's MatMul+Add fusion emits
 * Gemm, whose WebGPU kernel is a naive one, and on this encoder that costs more
 * than every fusion gains. Measured three times across two graph shapes:
 * "disabled" equals "basic", and "extended" is worse.
 *
 * @param {object} o
 * @param {any} o.ort
 * @param {Record<string, ArrayBuffer|Uint8Array>} o.models graphs by model name
 * @param {Record<string, object>} [o.weights] external data by model name
 * @param {Record<string, any[]>} [o.providers] execution providers by model name
 * @param {(name: string) => void} [o.onModel] called after each session is
 *   built, so the caller can release that model's bytes before the next
 * @param {() => void} [o.onLoaded] called once every session exists
 */
export async function createVozSessions({
  ort,
  models,
  weights = {},
  providers = {},
  ep = "webgpu",
  onModel,
  onLoaded,
}) {
  const base = { executionProviders: [ep], graphOptimizationLevel: "disabled" };
  const sessions = {};
  for (const [name, bytes] of Object.entries(models)) {
    const external = weights[name];
    const options = providers[name] ? { ...base, executionProviders: providers[name] } : base;
    sessions[name] = await ort.InferenceSession.create(
      bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes),
      external ? { ...options, externalData: [external] } : options,
    );
    // Hand this model's bytes back before compiling the next one.
    onModel?.(name);
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
 * @param {any} o.ort the onnxruntime-web module
 * @param {string} [o.wasmDir] where the runtime's own .wasm files live
 * @param {boolean} [o.webnn] override the WebNN detection
 * @param {(url: string, name: string) => Promise<ArrayBuffer|Uint8Array>} [o.fetchFile]
 * @param {string} [o.ep] execution provider for the graphs; "webgpu" by
 *   default, "wasm" to run on the CPU where there is no usable GPU
 * @returns the host, the manifest, and the sidecars the core needs at load
 */
export async function loadVoz({
  baseUrl, ort: supplied, wasmDir, webnn = hasWebNN(), fetchFile, ep = "webgpu",
}) {
  const ort = configureOrt({ ort: supplied, wasmDir });
  const { meta, metaBytes, step, files } = await fetchVozBundle(baseUrl, { webnn, fetchFile });

  const weights = {};
  if (meta.encoder_external) {
    // Already in the layout the graph expects: no expansion, and the bytes the
    // browser downloaded are the bytes the GPU gets.
    weights.encoder = { path: meta.encoder_external, data: files[meta.encoder_external] };
  } else if (meta.encoder_packed) {
    weights.encoder = {
      path: meta.encoder_packed.target,
      data: expand(files[meta.encoder_packed.blob], meta.encoder_packed),
    };
  }

  const sessions = await createVozSessions({
    ort,
    ep,
    models: { encoder: files["encoder.onnx"], decoder: files[step.file] },
    weights,
    providers: webnn ? { decoder: [{ name: "webnn", deviceType: "npu" }] } : {},
    // Every byte we downloaded is dead once the runtime has compiled it, and
    // holding them is not free: the weights alone are 349 MB, next to the
    // ~900 MB the runtime itself keeps for the compiled session. Released as
    // each session is built rather than after both, so the peak never holds
    // two models' bytes at once.
    onModel: (name) => {
      if (name === "encoder") {
        delete weights.encoder;
        delete files["encoder.onnx"];
        delete files[meta.encoder_external ?? meta.encoder_packed?.blob];
      } else {
        delete files[step.file];
      }
    },
    onLoaded: () => {
      delete weights.encoder;
      delete files[meta.encoder_external ?? meta.encoder_packed?.blob];
    },
  });

  return {
    host: makeVozHost({ ort, sessions }).install(),
    meta,
    // Bytes, because that is what the core's `load` takes.
    metaBytes,
    vocab: files["vocab.json"],
    embedding: files["embedding.f16"],
  };
}
