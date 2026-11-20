/// Which of the strokes already on a canvas belong to the drawing being made,
/// for live snapping: the strokes that followed each other with no pause longer
/// than `gap`, at most `limit` strokes counting the one being drawn. A plus or a
/// cross drawn in two strokes is then read as one drawing.
struct StrokeGroup: Sendable, Equatable {
    /// The longest pause between strokes of one drawing, in seconds; 0 reads
    /// every stroke on its own.
    let gap: Double
    /// The most strokes in one drawing.
    let limit: Int
    /// The index on the canvas of the drawing's first stroke.
    private(set) var first = 0
    /// When the last stroke ended, on the same clock as `began(at:count:)`.
    private var lastEnd: Double?

    init(gap: Double, limit: Int = 4) {
        self.gap = gap
        self.limit = max(1, limit)
    }

    /// A stroke starts at `time`, with `count` strokes already on the canvas.
    mutating func began(at time: Double, count: Int) {
        let joins = gap > 0 && first <= count && lastEnd.map { time - $0 <= gap } == true
        if !joins { first = count }
        first = max(first, count - (limit - 1))
    }

    /// The stroke being drawn ended at `time`.
    mutating func ended(at time: Double) {
        lastEnd = time
    }

    /// The canvas changed another way (a snap, an undo, the eraser): the next
    /// stroke starts a new drawing.
    mutating func reset(count: Int) {
        first = count
        lastEnd = nil
    }

    /// The drawing's earlier strokes, as indices into the canvas's strokes, when
    /// `count` strokes are on it.
    func earlier(count: Int) -> Range<Int> {
        min(first, count)..<count
    }
}
