package ai.desertant.core

/**
 * What the on-device harness (:androidtest) needs from HostBridge's internals,
 * checked by the compiler instead of reached by reflection.
 *
 * This is the debug source set: :androidtest's instrumented build compiles
 * against core's debug variant, while the published AAR is the release
 * variant, which does not contain this file. So none of it is public API.
 */
object HostBridgeTestHooks {
    /** [HostBridge.lastHttpRequestError]: why the last httpRequest returned null. */
    var lastHttpRequestError: Throwable?
        get() = HostBridge.lastHttpRequestError
        set(value) {
            HostBridge.lastHttpRequestError = value
        }
}
