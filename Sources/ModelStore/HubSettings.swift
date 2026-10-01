import PlatformSupport
#if os(WASI)
import JavaScriptKit
#endif

/// A Hub setting from the environment, or on wasm from `globalThis[global]`, then Node's `process.env`.
func hubSetting(_ name: String, global: String) -> String? {
#if os(WASI)
    let value = JSObject.global[global].string ?? JSObject.global.process.object?.env.object?[name].string
#else
    let value = environmentVariable(name)
#endif
    return value?.isEmpty == false ? value : nil
}

/// `DAL_HF_REPO_SUFFIX` points downloads at a copy of each repo, e.g. `-staging`.
func hubRepo(_ repo: String) -> String {
    repo + (hubSetting("DAL_HF_REPO_SUFFIX", global: "__dalHfRepoSuffix") ?? "")
}

/// `HF_TOKEN` as an `Authorization` value, for Hugging Face URLs only.
func hubAuthorization(for url: String) -> String? {
    guard url.hasPrefix("https://huggingface.co/"),
          let token = hubSetting("HF_TOKEN", global: "__dalHfToken") else { return nil }
    return "Bearer \(token)"
}
