// wasm entry point for __PRODUCT__: exposes the pipeline to JavaScript through
// JavaScriptKit. packages/__MODEL__-node's browser.js drives this via the
// `__EXPORTSGLOBAL__` global; inference runs through the JS host session
// (see desert-ant-core's JSInferenceSession) that browser.js installs on
// `__HOSTGLOBAL__`.
#if os(WASI)
@_spi(__PRODUCT__Bindings) import __PRODUCT__
import Inference
import JavaScriptEventLoop
import JavaScriptKit

@main
struct Main {
    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        var core: __PRODUCT__?

        let exports = JSObject.global.Object.function!.new()

        // load(cacheRoot, directory, onProgress) -> Promise
        exports.load = JSClosure { args in
            let cacheRoot = args.count > 0 ? args[0].string ?? "" : ""
            let directory = args.count > 1 ? args[1].string ?? "" : ""
            return JSPromise(resolver: { resolve in
                Task {
                    do {
                        let instance = __PRODUCT__(directory: directory.isEmpty ? nil : directory,
                                           cacheRoot: cacheRoot.isEmpty ? nil : cacheRoot)
                        try await instance.download()
                        core = instance
                        resolve(.success(.undefined))
                    } catch {
                        resolve(.failure(JSError(message: "\(error)").jsValue))
                    }
                }
            }).jsValue
        }.jsValue

        // loadBundled(metaJSON) -> Promise  (the modelBaseUrl opt-out)
        exports.loadBundled = JSClosure { args in
            let metaJSON = args.count > 0 ? args[0].string ?? "" : ""
            return JSPromise(resolver: { resolve in
                Task {
                    do {
                        let session = try JSInferenceSession(hostGlobal: "__HOSTGLOBAL__")
                        core = __PRODUCT__(assets: ModelAssets(metaJSON: metaJSON, session: session))
                        resolve(.success(.undefined))
                    } catch {
                        resolve(.failure(JSError(message: "\(error)").jsValue))
                    }
                }
            }).jsValue
        }.jsValue

        // run(input, minimumConfidence) -> Promise<result | null>
        exports.run = JSClosure { args in
            let input = args.count > 0 ? args[0].string ?? "" : ""
            let minimumConfidence = args.count > 1 ? args[1].number ?? 0 : 0
            return JSPromise(resolver: { resolve in
                Task {
                    do {
                        guard let core else { throw __PRODUCT__Error.notReady }
                        guard let result = try await core.run(input, minimumConfidence: minimumConfidence) else {
                            resolve(.success(.null)); return
                        }
                        let out = JSObject.global.Object.function!.new()
                        out.label = .string(result.label)
                        out.confidence = .number(result.confidence)
                        resolve(.success(out.jsValue))
                    } catch {
                        resolve(.failure(JSError(message: "\(error)").jsValue))
                    }
                }
            }).jsValue
        }.jsValue

        JSObject.global.__EXPORTSGLOBAL__ = exports
    }
}
#endif
