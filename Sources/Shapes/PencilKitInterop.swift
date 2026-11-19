#if canImport(PencilKit)
import PencilKit

public extension Stroke {
    /// A PencilKit stroke: its points mapped through its transform into canvas
    /// coordinates, and its times from its path's creation date.
    init(_ stroke: PKStroke) {
        let transform = stroke.transform
        let start = stroke.path.creationDate.timeIntervalSinceReferenceDate
        self.init(points: stroke.path.map { Point($0.location.applying(transform)) },
                  times: stroke.path.map { (start + $0.timeOffset) * 1000 })
    }
}

public extension Shapes {
    /// Recognize a PencilKit stroke. Returns the clean ``Shape``, or `nil` for a
    /// stroke that isn't a shape.
    func recognize(_ stroke: PKStroke, options: Options = .init()) async throws -> Shape? {
        try await recognize(strokes: [Stroke(stroke)], options: options)
    }

    /// Recognize PencilKit strokes drawn together, such as a cross. Returns the
    /// clean ``Shape``, or `nil` for ink that isn't a shape.
    func recognize(_ strokes: [PKStroke], options: Options = .init()) async throws -> Shape? {
        try await recognize(strokes: strokes.map(Stroke.init), options: options)
    }
}
#endif
