/// A 2D point in the same coordinate space as the input stroke.
///
/// The cross-platform value type used throughout the public API. On Apple
/// platforms `CoreGraphics` conveniences convert to and from `CGPoint` (see the
/// `CGPoint` interop), so existing call sites keep working.
public struct Point: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
