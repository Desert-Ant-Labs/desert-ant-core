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
    private let closure: JSClosure

    init(onBackground: @escaping @Sendable () -> Void) {
        let cb = JSClosure { _ in onBackground(); return .undefined }
        // visibilitychange (hidden) is the reliable flush point; pagehide covers
        // actual unload. The transport's beacon path (sendBeacon) survives unload.
        _ = JSObject.global.document.object?.addEventListener?("visibilitychange", cb.jsValue)
        _ = JSObject.global.addEventListener?("pagehide", cb.jsValue)
        self.closure = cb
    }

    deinit {
        _ = JSObject.global.document.object?.removeEventListener?("visibilitychange", closure.jsValue)
        _ = JSObject.global.removeEventListener?("pagehide", closure.jsValue)
        #if JAVASCRIPTKIT_WITHOUT_WEAKREFS
        closure.release()
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
