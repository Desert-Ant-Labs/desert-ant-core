#if !os(WASI)
import Dispatch

private final class BlockingBox<Value: Sendable>: @unchecked Sendable {
    var value: Value?
}

/// Run an async operation to completion while blocking the current host worker
/// thread. Use this only at synchronous FFI boundaries, never on an app's main
/// thread.
public func blockingValue<Value: Sendable>(
    _ operation: @escaping @Sendable () async -> Value
) -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = BlockingBox<Value>()
    Task.detached {
        box.value = await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}
#endif
