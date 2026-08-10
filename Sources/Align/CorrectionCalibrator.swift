import Foundation

/// Tiny validation-trained gradient-boosted correction policy.
///
/// It maps coarse/fine distribution statistics and boundary metadata to a calibrated
/// correction in seconds. Stored as compact binary trees so it adds no Core ML invocation.
final class CorrectionCalibrator: @unchecked Sendable {
    struct Node {
        let value: Float
        let threshold: Float
        let feature: Int
        let left: Int
        let right: Int
        let isLeaf: Bool
        let missingLeft: Bool
    }

    private let baseline: Float
    private let trees: [[Node]]
    let featureCount: Int

    init(url: URL) throws {
        var reader = BinaryReader(data: try Data(contentsOf: url))
        guard try reader.bytes(4) == Data("ALGN".utf8) else { throw CalibratorError.invalidFormat }
        guard try reader.uint32() == 1 else { throw CalibratorError.unsupportedVersion }
        featureCount = Int(try reader.uint32())
        let treeCount = Int(try reader.uint32())
        baseline = try reader.float32()
        var parsed: [[Node]] = []
        parsed.reserveCapacity(treeCount)
        for _ in 0..<treeCount {
            let count = Int(try reader.uint32())
            var nodes: [Node] = []
            nodes.reserveCapacity(count)
            for _ in 0..<count {
                let value = try reader.float32()
                let threshold = try reader.float32()
                let feature = Int(try reader.uint8())
                let flags = try reader.uint8()
                let left = Int(try reader.uint16())
                let right = Int(try reader.uint16())
                _ = try reader.uint16()
                nodes.append(Node(
                    value: value,
                    threshold: threshold,
                    feature: feature,
                    left: left,
                    right: right,
                    isLeaf: flags & 1 != 0,
                    missingLeft: flags & 2 != 0
                ))
            }
            parsed.append(nodes)
        }
        guard featureCount == 27, parsed.count == treeCount, reader.isAtEnd else {
            throw CalibratorError.invalidFormat
        }
        trees = parsed
    }

    func correction(features: [Float]) -> Double {
        guard features.count == featureCount else { return 0 }
        var result = baseline
        for tree in trees {
            var index = 0
            while !tree[index].isLeaf {
                let node = tree[index]
                let value = features[node.feature]
                if value.isNaN {
                    index = node.missingLeft ? node.left : node.right
                } else {
                    index = value <= node.threshold ? node.left : node.right
                }
            }
            result += tree[index].value
        }
        return Double(result)
    }

    enum CalibratorError: Error {
        case invalidFormat
        case unsupportedVersion
        case unexpectedEnd
    }

    private struct BinaryReader {
        let data: Data
        var offset = 0
        var isAtEnd: Bool { offset == data.count }

        mutating func bytes(_ count: Int) throws -> Data {
            guard offset + count <= data.count else { throw CalibratorError.unexpectedEnd }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func uint8() throws -> UInt8 {
            guard offset < data.count else { throw CalibratorError.unexpectedEnd }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func uint16() throws -> UInt16 {
            let value: UInt16 = try load(UInt16.self)
            return UInt16(littleEndian: value)
        }

        mutating func uint32() throws -> UInt32 {
            let value: UInt32 = try load(UInt32.self)
            return UInt32(littleEndian: value)
        }

        mutating func float32() throws -> Float {
            Float(bitPattern: try uint32())
        }

        private mutating func load<T>(_ type: T.Type) throws -> T {
            let count = MemoryLayout<T>.size
            guard offset + count <= data.count else { throw CalibratorError.unexpectedEnd }
            defer { offset += count }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
    }
}
