/// Call `body` with parallel arrays of base pointers and byte lengths for
/// `buffers`, keeping every buffer pinned for the duration of the call.
///
/// Shared by the native backends, which both hand a C shim an array of input
/// buffers: nesting `withUnsafeBytes` per buffer is the only way to guarantee
/// all of them stay pinned at once, and the recursion is what makes that work
/// for a count known only at runtime.
func withByteBuffers<R>(
    _ buffers: [[UInt8]],
    _ body: (_ pointers: UnsafePointer<UnsafeRawPointer?>, _ lengths: UnsafePointer<Int>) -> R
) -> R {
    func recurse(_ i: Int, _ pointers: inout [UnsafeRawPointer?], _ lengths: inout [Int]) -> R {
        if i == buffers.count {
            return pointers.withUnsafeBufferPointer { p in
                lengths.withUnsafeBufferPointer { l in body(p.baseAddress!, l.baseAddress!) }
            }
        }
        return buffers[i].withUnsafeBytes { raw in
            pointers[i] = raw.baseAddress
            lengths[i] = raw.count
            return recurse(i + 1, &pointers, &lengths)
        }
    }
    if buffers.isEmpty {
        return body(UnsafePointer(bitPattern: MemoryLayout<UnsafeRawPointer?>.alignment)!,
                    UnsafePointer(bitPattern: MemoryLayout<Int>.alignment)!)
    }
    var pointers = [UnsafeRawPointer?](repeating: nil, count: buffers.count)
    var lengths = [Int](repeating: 0, count: buffers.count)
    return recurse(0, &pointers, &lengths)
}
