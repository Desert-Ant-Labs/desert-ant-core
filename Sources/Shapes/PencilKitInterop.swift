#if canImport(PencilKit)
import PencilKit

public extension Shapes {
    /// Recognize a PencilKit stroke. The stroke's control points are mapped
    /// through its transform into canvas coordinates, then recognized. Returns
    /// the snapped ``Shape``, or `nil` when rejected or degenerate.
    func recognize(_ stroke: PKStroke, options: Options = .init()) async throws -> Shape? {
        let transform = stroke.transform
        let points = stroke.path.map { $0.location.applying(transform) }
        return try await recognize(points: points, options: options)
    }
}
#endif
