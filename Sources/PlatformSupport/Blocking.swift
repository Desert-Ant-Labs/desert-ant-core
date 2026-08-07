#if !os(WASI)
import Dispatch

private final class BlockingBox<Value: Sendable>: @unchecked Sendable {
    var value: Value?
}

/// Hands one non-Sendable value to the operation `blockingValue` runs.
///
/// The unchecked claim is true because of what `blockingValue` does: the calling
/// thread blocks until the operation finishes, so the value is touched by exactly
/// one thread at a time. A model is not Sendable (a LiteRT interpreter is not
/// thread-safe, which is why Clear pools sessions), and two host threads calling
/// one handle concurrently is the host's contract to avoid - as it was before the
/// language could say so. Keeping the assertion here means no FFI entry point has
/// to make it.
private struct Transferred<Value>: @unchecked Sendable {
    let value: Value
}

/// Run an async operation to completion while blocking the current host worker
/// thread, handing it `input`. Use this only at synchronous FFI boundaries, never
/// on an app's main thread.
public func blockingValue<Value: Sendable, Input>(
    with input: Input,
    _ operation: @escaping @Sendable (Input) async -> Value
) -> Value {
    let transferred = Transferred(value: input)
    return blockingValue { await operation(transferred.value) }
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
