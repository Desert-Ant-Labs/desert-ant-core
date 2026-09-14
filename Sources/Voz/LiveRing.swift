#if canImport(CoreML)
import Foundation

/// A growable window of the most recent audio, written from the capture thread
/// and read from the recognition task.
///
/// Streaming reads each sample once and never looks further back than the chunk
/// it is working on, so everything behind the next chunk's window is dropped.
/// That is what keeps a dictation session the same footprint at ten minutes as
/// at ten seconds; the window itself is `nRows` rows, a few hundred
/// milliseconds.
///
/// `@unchecked Sendable` with a lock rather than an actor, because ``append`` is
/// called from a CoreAudio render callback. Awaiting an actor there would mean
/// hopping off the audio thread on every buffer, and the callback has a hard
/// deadline it must not miss. An uncontended `NSLock` is a few tens of
/// nanoseconds; the recognition task holds it only to copy out a chunk's span.
final class LiveRing: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ContiguousArray<Float> = []
    /// Stream index of `storage[0]`.
    private var base = 0
    /// Samples ever appended, which is the stream's length.
    private var appended = 0
    private var closed = false
    /// When the most recent append landed.
    ///
    /// The SDK cannot know when a microphone captured a sample, only when the
    /// caller handed it over, so this is the earliest honest reference point
    /// for "how long did the model take". A caller pushing at capture rate makes
    /// the two the same thing.
    private var lastAppend = Date()
    /// The utterance kept for the second pass, if one is running.
    ///
    /// Held here rather than in the actor because ``append(_:)`` is nonisolated:
    /// hopping to the actor to accumulate it means a caller that appends
    /// everything and immediately calls `finish()` can race its own audio, and
    /// the second pass then sees an empty buffer and silently returns nothing.
    /// One lock, one ordering.
    private var retained: ContiguousArray<Float> = []
    private var retaining = false
    private var retainCap = 0

    /// How many samples the stream has seen, whether or not they are still held.
    var streamLength: Int {
        lock.lock(); defer { lock.unlock() }
        return appended
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Wall clock of the most recent append.
    var lastAppendAt: Date {
        lock.lock(); defer { lock.unlock() }
        return lastAppend
    }

    /// Start keeping the whole utterance, up to `cap` samples.
    func retain(upTo cap: Int) {
        lock.lock()
        retaining = true
        retainCap = cap
        retained.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Seconds of utterance held for the second pass.
    var retainedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return retained.count
    }

    /// Copy `[from, to)` of the retained utterance out.
    ///
    /// A copy, and a bounded one: the refiner reads at most its window, which
    /// is under a megabyte, and the model then runs outside the lock.
    func copyRetained(from: Int, to: Int, into destination: inout [Float]) {
        lock.lock(); defer { lock.unlock() }
        let low = Swift.max(0, from)
        let high = Swift.min(retained.count, to)
        guard high > low else { destination.removeAll(keepingCapacity: true); return }
        destination.removeAll(keepingCapacity: true)
        destination.append(contentsOf: retained[low..<high])
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let now = Date()
        lock.lock()
        storage.append(contentsOf: samples)
        appended += samples.count
        if retaining && retained.count < retainCap {
            retained.append(contentsOf: samples)
        }
        lastAppend = now
        lock.unlock()
    }

    func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    /// Append `count` zeros, which is how a session flushes its last partial
    /// chunk: the model needs a whole window and silence is the honest padding.
    func appendSilence(_ count: Int) {
        guard count > 0 else { return }
        let now = Date()
        lock.lock()
        storage.append(contentsOf: repeatElement(0, count: count))
        appended += count
        lastAppend = now
        lock.unlock()
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        base = 0
        appended = 0
        closed = false
        lastAppend = Date()
        retained.removeAll(keepingCapacity: true)
        retaining = false
        lock.unlock()
    }

    /// Copy `count` samples from stream index `from` into `destination`,
    /// zero-filling anything the ring does not hold.
    ///
    /// A copy rather than lending the storage out, because the caller then runs
    /// a model over it for tens of milliseconds and the lock must not be held
    /// for that: ``append(_:)`` is called from an audio render callback with a
    /// hard deadline, and blocking it that long is a dropped buffer. The copy
    /// is one chunk's window, a few thousand samples, and is what a render
    /// callback actually waits on.
    ///
    /// Zero outside the ring is correct at both ends: at the start of a stream
    /// it is the `center=True` padding the frontend expects, and past the end
    /// it is the silence a flush pads with.
    func copyWindow(from: Int, count: Int, into destination: inout [Float]) {
        if destination.count < count {
            destination = [Float](repeating: 0, count: count)
        }
        destination.withUnsafeMutableBufferPointer { out in
            guard let target = out.baseAddress else { return }
            target.update(repeating: 0, count: count)
            lock.lock(); defer { lock.unlock() }
            let low = Swift.max(from, base)
            let high = Swift.min(from + count, base + storage.count)
            guard high > low else { return }
            storage.withUnsafeBufferPointer { source in
                guard let origin = source.baseAddress else { return }
                (target + (low - from)).update(from: origin + (low - base),
                                               count: high - low)
            }
        }
    }

    /// Drop everything before stream index `absolute`.
    ///
    /// Rebuilt rather than `removeFirst`: that keeps the array's capacity, so
    /// the storage would stay as large as the longest span ever held and a long
    /// session would never give memory back.
    func release(before absolute: Int) {
        lock.lock(); defer { lock.unlock() }
        let drop = Swift.min(Swift.max(absolute - base, 0), storage.count)
        guard drop > 0 else { return }
        storage = ContiguousArray(storage[drop...])
        base += drop
    }
}
#endif
