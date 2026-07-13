/// A dense tensor crossing an inference boundary, in host byte order.
///
/// One value type shared by every backend (Core ML, ONNX Runtime, a JS host):
/// model SDKs build named input tensors, run the session, and read named
/// outputs. Storage is raw bytes so backends move data without caring about
/// the element type; the typed accessors copy out on demand (memcpy, so large
/// tensors are fine).
public struct Tensor: Sendable {
    /// The element types models exchange. (float16 I/O can be added as a raw
    /// passthrough when a model needs it; exporters should prefer these.)
    public enum Element: String, Sendable {
        case int32
        case int64
        case float32

        /// Bytes per element.
        public var stride: Int {
            switch self {
            case .int32, .float32: return 4
            case .int64: return 8
            }
        }
    }

    public let element: Element
    public let shape: [Int]
    public let bytes: [UInt8]

    /// Total element count (the product of `shape`).
    public var count: Int { shape.reduce(1, *) }

    /// A raw-bytes tensor (backends and FFI edges); validates the byte count
    /// against the shape.
    public init(element: Element, shape: [Int], bytes: [UInt8]) throws {
        let count = shape.reduce(1, *)
        guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }), bytes.count == count * element.stride else {
            throw InferenceError.invalidTensor(
                "shape \(shape) of \(element.rawValue) does not match \(bytes.count) bytes")
        }
        self.element = element
        self.shape = shape
        self.bytes = bytes
    }

    public init(int32 values: [Int32], shape: [Int]) { self.init(unchecked: .int32, shape: shape, values: values) }
    public init(int64 values: [Int64], shape: [Int]) { self.init(unchecked: .int64, shape: shape, values: values) }
    public init(float32 values: [Float], shape: [Int]) { self.init(unchecked: .float32, shape: shape, values: values) }

    private init<T>(unchecked element: Element, shape: [Int], values: [T]) {
        precondition(values.count == shape.reduce(1, *), "shape \(shape) does not match \(values.count) values")
        self.element = element
        self.shape = shape
        self.bytes = values.withUnsafeBytes { Array($0) }
    }

    /// The elements as `Int32`, or `nil` if the tensor holds another type.
    public var int32Values: [Int32]? { values(.int32) }
    /// The elements as `Int64`, or `nil` if the tensor holds another type.
    public var int64Values: [Int64]? { values(.int64) }
    /// The elements as `Float`, or `nil` if the tensor holds another type.
    public var float32Values: [Float]? { values(.float32) }

    private func values<T>(_ expected: Element) -> [T]? {
        guard element == expected else { return nil }
        let count = self.count
        return [T](unsafeUninitializedCapacity: count) { destination, initialized in
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(destination).copyMemory(from: source)
            }
            initialized = count
        }
    }
}
