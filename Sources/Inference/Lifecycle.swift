// Platform "app backgrounded / page hidden" hooks, so pending usage is sent
// before the app or tab goes away. Best-effort per platform:
//
//   Apple    NotificationCenter (app-background / resign-active / terminate)
//   WASI     document `visibilitychange` + window `pagehide` (browser)
//   Android  a registry flushed by HostBridge.flushUsage(), which the host calls
//            from a lifecycle callback (e.g. ProcessLifecycleOwner ON_STOP)
//
// A `LifecycleObserver` installs the hooks and removes them on deinit. It's
// created lazily on the first inference run, so a session that never runs
// installs nothing (and there is nothing to flush).

#if canImport(Foundation) && (os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(macOS))
import Foundation
#elseif os(WASI)
import JavaScriptKit
#elseif os(Android)
import Android
#endif

final class LifecycleObserver {
#if canImport(Foundation) && (os(iOS) || os(tvOS) || os(visionOS) || os(watchOS) || os(macOS))
    private var tokens: [NSObjectProtocol] = []

    init(onBackground: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        for name in Self.names {
            tokens.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in
                onBackground()
            })
        }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    // Raw names (avoid importing UIKit/AppKit). macOS has no "background", so use
    // resign-active + terminate; iOS-family uses enter-background + terminate.
    private static var names: [String] {
        #if os(macOS)
        ["NSApplicationWillResignActiveNotification", "NSApplicationWillTerminateNotification"]
        #else
        ["UIApplicationDidEnterBackgroundNotification", "UIApplicationWillTerminateNotification"]
        #endif
    }

#elseif os(WASI)
    private let hidden: JSClosure
    private let unload: JSClosure

    init(onBackground: @escaping @Sendable () -> Void) {
        // visibilitychange fires on both directions, so only the hidden edge is a
        // background event - flushing when the tab comes *back* stamps the idle
        // clock for no reason. pagehide covers actual unload (the transport's
        // beacon path survives it).
        hidden = JSClosure { _ in
            if JSObject.global.document.object?.visibilityState.string == "hidden" { onBackground() }
            return .undefined
        }
        unload = JSClosure { _ in onBackground(); return .undefined }
        _ = JSObject.global.document.object?.addEventListener?("visibilitychange", hidden.jsValue)
        _ = JSObject.global.addEventListener?("pagehide", unload.jsValue)
    }

    deinit {
        _ = JSObject.global.document.object?.removeEventListener?("visibilitychange", hidden.jsValue)
        _ = JSObject.global.removeEventListener?("pagehide", unload.jsValue)
        #if JAVASCRIPTKIT_WITHOUT_WEAKREFS
        hidden.release()
        unload.release()
        #endif
    }

#elseif os(Android)
    private let id: Int
    init(onBackground: @escaping @Sendable () -> Void) { id = androidUsageRegistry.add(onBackground) }
    deinit { androidUsageRegistry.remove(id) }
#else
    init(onBackground: @escaping @Sendable () -> Void) {}
#endif
}

#if os(Android)
/// Active flush hooks, flushed by `HostBridge.flushUsage()` (the Kotlin host
/// calls it from a lifecycle callback). Thread-safe.
final class UsageRegistry: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    private var hooks: [Int: @Sendable () -> Void] = [:]
    private var nextID = 0

    init() { pthread_mutex_init(&mutex, nil) }

    func add(_ hook: @escaping @Sendable () -> Void) -> Int {
        pthread_mutex_lock(&mutex); defer { pthread_mutex_unlock(&mutex) }
        let id = nextID; nextID += 1; hooks[id] = hook; return id
    }
    func remove(_ id: Int) {
        pthread_mutex_lock(&mutex); defer { pthread_mutex_unlock(&mutex) }
        hooks[id] = nil
    }
    func flushAll() {
        pthread_mutex_lock(&mutex)
        let all = Array(hooks.values)
        pthread_mutex_unlock(&mutex)
        for hook in all { hook() }
    }
}

let androidUsageRegistry = UsageRegistry()

/// JNI entry the Kotlin host calls on background (`HostBridge.flushUsage()`).
@_cdecl("Java_ai_desertant_core_HostBridge_flushUsage")
public func Java_ai_desertant_core_HostBridge_flushUsage(_ env: UnsafeMutablePointer<JNIEnv?>, _ clazz: jclass?) {
    androidUsageRegistry.flushAll()
}
#endif
