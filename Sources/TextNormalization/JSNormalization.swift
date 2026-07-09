// NFKC via the JS host's String.prototype.normalize on WebAssembly, keeping ICU
// out of the wasm payload.
#if os(WASI)
import JavaScriptKit

private let jsNormalize: JSObject =
    JSObject.global.Function.function!.new("s", "return s.normalize('NFKC')")

func nfkcNormalize(_ s: String) -> String { jsNormalize(s).string ?? s }
#endif
