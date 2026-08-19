#if os(iOS) || os(visionOS)
import PencilKit
import UIKit

/// Tunables for live shape snapping on a `PKCanvasView`.
public struct ShapeSnappingConfiguration: Sendable {
    /// How long the pen must pause (no significant movement) before a preview
    /// appears, in seconds.
    public var pauseDelay: TimeInterval = 0.3
    /// Opacity of the faded preview shown while the pen is still down.
    public var previewOpacity: Float = 0.5

    /// Creates a configuration with default values.
    public init() {}
}

public extension PKCanvasView {
    /// Recognize and snap hand-drawn strokes to clean shapes, in one line.
    ///
    /// While drawing, pausing briefly shows a faded preview of the recognized
    /// shape; lifting the pen replaces the raw stroke with the clean one. The
    /// swap is registered with the canvas's undo manager, so undo/redo work.
    /// Call again to update the recognizer or configuration;
    /// ``disableShapeSnapping()`` to stop.
    ///
    /// - Parameter shapes: the recognizer to use. The default downloads the
    ///   model on demand and caches it. For instant, offline snapping pass a
    ///   recognizer over a directory you already populated,
    ///   `Shapes(directory: myModelDir)`.
    func enableShapeSnapping(using shapes: Shapes = Shapes(),
                             configuration: ShapeSnappingConfiguration = .init()) {
        disableShapeSnapping()
        let snapper = ShapeSnapper(canvasView: self, shapes: shapes, configuration: configuration)
        objc_setAssociatedObject(self, &shapeSnapperKey, snapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Stop shape snapping and remove its observers and preview overlay.
    func disableShapeSnapping() {
        shapeSnapper?.detach()
        objc_setAssociatedObject(self, &shapeSnapperKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Whether shape snapping is currently enabled on this canvas.
    var isShapeSnappingEnabled: Bool {
        get { shapeSnapper != nil }
        set { newValue ? enableShapeSnapping() : disableShapeSnapping() }
    }

    private var shapeSnapper: ShapeSnapper? {
        objc_getAssociatedObject(self, &shapeSnapperKey) as? ShapeSnapper
    }
}

// Only this variable's *address* is used, as the unique key an associated object
// is filed under; its value is never read or written. There is therefore no
// shared mutable state to protect, which `nonisolated(unsafe)` states - a `let`
// would be the honest spelling but cannot be passed as the `inout` the ObjC
// runtime's key parameter expects.
private nonisolated(unsafe) var shapeSnapperKey: UInt8 = 0

// MARK: - ShapeSnapper

/// Watches a canvas for a draw → pause → lift gesture and snaps the stroke.
///
/// Recognition runs through the shared ``Shapes`` recognizer (the Core ML
/// model). It is `async`, so results are delivered back on the main actor and
/// guarded by a generation counter, and stale results from an earlier pen state
/// are discarded.
///
/// Main-actor isolated: every member touches the canvas, the overlay, or UIKit
/// touch state, and every entry point is already a main-thread callback (a
/// gesture recognizer, a `PKCanvasViewDelegate` message, or a main-queue timer).
@MainActor
final class ShapeSnapper: NSObject {
    private weak var canvas: PKCanvasView?
    private let shapes: Shapes
    private let configuration: ShapeSnappingConfiguration
    // Read from `responds(to:)` and `forwardingTarget(for:)`, which NSObject
    // declares `nonisolated` so an override cannot be isolated either. It is
    // written only from attach/detach on the main thread, and read only while
    // UIKit is delivering a delegate message, so the ObjC runtime's own
    // messaging is the synchronization here.
    private nonisolated(unsafe) weak var previousDelegate: PKCanvasViewDelegate?
    private let overlay = PreviewOverlay()
    private var observer: TouchObserver?

    private var lastSignificant: CGPoint = .zero
    private var strokeCountAtStart = 0
    private var penDown = false
    private var previewing = false
    private var currentShape: Shape?
    private var pendingSnap = false
    private var isProgrammatic = false
    private var pauseWork: DispatchWorkItem?
    /// Bumped on every pen-down / significant move so stale async recognition
    /// results are ignored.
    private var generation = 0

    /// Movement under this distance (points) doesn't reset the pause timer.
    private static let movementTolerance: CGFloat = 6
    /// Strokes whose bounding-box diagonal is smaller than this are ignored.
    private static let minimumExtent: CGFloat = 24

    init(canvasView: PKCanvasView, shapes: Shapes, configuration: ShapeSnappingConfiguration) {
        self.shapes = shapes
        self.configuration = configuration
        canvas = canvasView
        super.init()
        // Warm the model so the first pause preview is instant.
        Task { try? await shapes.download() }
        attach()
    }

    func detach() {
        cancelPause()
        hidePreview()
        overlay.removeFromSuperview()
        if let canvas {
            if let observer { canvas.removeGestureRecognizer(observer) }
            if canvas.delegate === self { canvas.delegate = previousDelegate }
        }
        observer = nil
    }

    // MARK: Setup

    private func attach() {
        guard let canvas else { return }
        previousDelegate = canvas.delegate
        canvas.delegate = self

        overlay.isUserInteractionEnabled = false
        canvas.addSubview(overlay)

        let obs = TouchObserver()
        obs.delegate = self
        obs.cancelsTouchesInView = false
        obs.delaysTouchesBegan = false
        obs.delaysTouchesEnded = false
        obs.began = { [weak self] t in self?.began(t) }
        obs.moved = { [weak self] t, e in self?.moved(t, e) }
        obs.ended = { [weak self] in self?.ended() }
        canvas.addGestureRecognizer(obs)
        observer = obs
    }

    // MARK: Touch tracking

    private func began(_ touch: UITouch) {
        guard let canvas else { return }
        penDown = true
        previewing = false
        pendingSnap = false
        currentShape = nil
        generation += 1
        cancelPause()
        hidePreview()
        strokeCountAtStart = canvas.drawing.strokes.count
        lastSignificant = touch.location(in: canvas)
    }

    private func moved(_ touch: UITouch, _ event: UIEvent) {
        guard penDown, let canvas else { return }
        let last = (event.coalescedTouches(for: touch)?.last ?? touch).location(in: canvas)
        if hypot(last.x - lastSignificant.x, last.y - lastSignificant.y) > Self.movementTolerance {
            lastSignificant = last
            if previewing {
                previewing = false
                currentShape = nil
                hidePreview()
            }
            generation += 1
            schedulePause()
        }
    }

    private func ended() {
        penDown = false
        cancelPause()
        guard previewing, currentShape != nil else { return }
        pendingSnap = true
        Task { @MainActor [weak self] in self?.snapIfPending() }
    }

    private func schedulePause() {
        cancelPause()
        let work = DispatchWorkItem { [weak self] in
            // The work item is only ever scheduled on the main queue below, so it
            // runs where this class is isolated; `assumeIsolated` states that
            // rather than hopping and letting the pause fire a turn late.
            MainActor.assumeIsolated { self?.detectAndPreview() }
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.pauseDelay, execute: work)
    }

    private func cancelPause() {
        pauseWork?.cancel()
        pauseWork = nil
    }

    // MARK: Recognition + preview

    private func detectAndPreview() {
        guard penDown, canvas?.tool is PKInkingTool,
              let stroke = inProgressStroke() else { return }
        // Recognize from the live PencilKit stroke itself — same coordinate space
        // as the ink, no separately accumulated points.
        let pts = strokePoints(stroke)
        guard pts.count >= 8 else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let extent = hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        guard extent >= Self.minimumExtent else { return }

        let token = generation
        Task { [weak self, shapes] in
            let shape = try? await shapes.recognize(points: pts)
            await MainActor.run { self?.applyPreview(shape, token: token) }
        }
    }

    private func applyPreview(_ shape: Shape?, token: Int) {
        guard penDown, token == generation else { return }
        guard let shape else {
            previewing = false
            currentShape = nil
            hidePreview()
            return
        }
        currentShape = shape
        previewing = true
        showPreview(shape)
    }

    private func showPreview(_ shape: Shape) {
        guard let canvas else { return }
        overlay.frame = canvas.bounds
        canvas.bringSubviewToFront(overlay)

        let stroke = makeStroke(shape, ink: currentInk(in: canvas), width: currentPreviewWidth())
        let drawing = PKDrawing(strokes: [stroke])
        let rect = CGRect(origin: canvas.contentOffset, size: canvas.bounds.size)
        let traits = canvas.window?.traitCollection ?? canvas.traitCollection
        let scale = traits.displayScale > 0 ? traits.displayScale : 2
        var image: UIImage?
        traits.performAsCurrent { image = drawing.image(from: rect, scale: scale) }
        overlay.imageView.image = image

        overlay.imageView.layer.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = configuration.previewOpacity
        fade.duration = 0.12
        overlay.imageView.layer.opacity = configuration.previewOpacity
        overlay.imageView.layer.add(fade, forKey: "in")
    }

    private func hidePreview() {
        overlay.imageView.layer.removeAllAnimations()
        overlay.imageView.layer.opacity = 0
        overlay.imageView.image = nil
    }

    // MARK: Snap (undo-preserving)

    private func snapIfPending() {
        guard pendingSnap, currentShape != nil, let canvas else { return }
        guard canvas.drawing.strokes.count > strokeCountAtStart,
              let last = canvas.drawing.strokes.last else { return }
        pendingSnap = false

        // Re-recognize from the committed stroke so the clean shape lands in the
        // exact coordinate space of the ink it replaces.
        let pts = strokePoints(last)
        let token = generation
        Task { [weak self, shapes] in
            let shape = try? await shapes.recognize(points: pts)
            await MainActor.run { self?.applySnap(shape, to: last, token: token) }
        }
    }

    private func applySnap(_ shape: Shape?, to last: PKStroke, token: Int) {
        guard token == generation, let canvas else { return }
        guard let shape else {
            previewing = false
            currentShape = nil
            hidePreview()
            return
        }
        let perfect = makeStroke(shape, ink: last.ink, width: drawnWidth(of: last))

        // Drop the raw stroke (coalesces with the user's draw in the undo stack),
        // then replace it with the clean one as a single undoable change.
        isProgrammatic = true
        canvas.undoManager?.undo()
        isProgrammatic = false
        setDrawing(PKDrawing(strokes: canvas.drawing.strokes + [perfect]), on: canvas)

        previewing = false
        currentShape = nil
        hidePreview()
    }

    private func setDrawing(_ drawing: PKDrawing, on canvas: PKCanvasView) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { [weak self] target in
            self?.setDrawing(previous, on: target)
        }
        isProgrammatic = true
        canvas.drawing = drawing
        isProgrammatic = false
    }

    // MARK: Shape → PKStroke

    private func makeStroke(_ shape: Shape, ink: PKInk, width: CGFloat) -> PKStroke {
        let outline = shape.cgOutline(samples: 96)
        // For closed shapes, start (and end) the loop at the midpoint of the first
        // edge so the path seam lands on a straight section rather than a corner
        // — otherwise that corner renders sharp while the spline rounds the others.
        let isLine: Bool
        if case .line = shape { isLine = true } else { isLine = false }
        let loop = isLine ? outline : Self.closedLoopFromMidEdge(outline)
        let pts = Self.densify(loop, maxSpacing: 6)
        let n = pts.count
        let sp = pts.enumerated().map { i, pt in
            PKStrokePoint(location: pt,
                          timeOffset: TimeInterval(i) / TimeInterval(max(n - 1, 1)),
                          size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: sp, creationDate: Date())
        // The standalone SDK also carried over the source stroke's render state
        // (grain-texture anchoring for pencil/crayon/marker) and its wet-ink
        // group, through `PKStroke(ink:path:transform:renderGroupID:renderState:)`.
        // That initializer is iOS 27 / visionOS 27, which this repo's pinned
        // Xcode has no SDK for, so it cannot even be compiled behind an
        // `#available` check here. Restore it when the toolchain moves.
        return PKStroke(ink: ink, path: path, transform: .identity)
    }

    /// Reorders a closed polygon's vertices so the loop begins and ends at the
    /// midpoint of the first edge: [mid(v0,v1), v1, v2, …, v0, mid(v0,v1)].
    private static func closedLoopFromMidEdge(_ v: [CGPoint]) -> [CGPoint] {
        guard v.count >= 2 else { return v }
        let mid = CGPoint(x: (v[0].x + v[1].x) / 2, y: (v[0].y + v[1].y) / 2)
        return [mid] + v.dropFirst() + [v[0], mid]
    }

    private static func densify(_ poly: [CGPoint], maxSpacing: CGFloat) -> [CGPoint] {
        guard poly.count >= 2 else { return poly }
        var out: [CGPoint] = []
        for i in 0..<(poly.count - 1) {
            let a = poly[i], b = poly[i + 1]
            let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) / maxSpacing).rounded(.up)))
            for j in 0..<steps {
                let f = CGFloat(j) / CGFloat(steps)
                out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        out.append(poly[poly.count - 1])
        return out
    }

    private var currentToolWidth: CGFloat {
        (canvas?.tool as? PKInkingTool)?.width ?? 7
    }

    /// Width for the live preview: the actual in-progress stroke's drawn width
    /// (pressure-aware) when available, else the tool's nominal width.
    private func currentPreviewWidth() -> CGFloat {
        inProgressStrokeWidth() ?? currentToolWidth
    }

    private func inProgressStrokeWidth() -> CGFloat? {
        guard let stroke = inProgressStroke() else { return nil }
        let w = drawnWidth(of: stroke)
        return (w.isFinite && w > 0.1 && w < 1000) ? w : nil
    }

    /// Path locations of a stroke in canvas coordinates.
    private func strokePoints(_ stroke: PKStroke) -> [CGPoint] {
        let t = stroke.transform
        return stroke.path.map { $0.location.applying(t) }
    }

    /// The stroke PencilKit is currently capturing (private API), if any.
    private func inProgressStroke() -> PKStroke? {
        guard penDown, let canvas else { return nil }
        let sel = NSSelectorFromString(["_", "current", "Stroke"].joined())
        guard canvas.responds(to: sel),
              let obj = canvas.perform(sel)?.takeUnretainedValue(),
              let stroke = obj as? PKStroke else { return nil }
        return stroke
    }

    private func currentInk(in canvas: PKCanvasView) -> PKInk {
        (canvas.tool as? PKInkingTool)?.ink ?? PKInk(.pen, color: .label)
    }

    private func drawnWidth(of stroke: PKStroke) -> CGFloat {
        let n = stroke.path.count
        guard n > 0 else { return currentToolWidth }
        var sizes = (0..<n).map { stroke.path[$0].size.width }
        sizes.sort()
        return sizes[n / 2]
    }
}

// MARK: PKCanvasViewDelegate (transparent passthrough)

extension ShapeSnapper: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !isProgrammatic, pendingSnap {
            Task { @MainActor [weak self] in self?.snapIfPending() }
        }
        previousDelegate?.canvasViewDrawingDidChange?(canvasView)
    }

    // The ObjC runtime asking which delegate messages this object handles, so
    // the ones it does not handle can be forwarded to the delegate it replaced.
    // NSObject declares both `nonisolated`; see `previousDelegate`.
    override nonisolated func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
    }

    override nonisolated func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let d = previousDelegate, d.responds(to: aSelector) { return d }
        return super.forwardingTarget(for: aSelector)
    }
}

// MARK: UIGestureRecognizerDelegate

extension ShapeSnapper: UIGestureRecognizerDelegate {
    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive _: UITouch) -> Bool { true }
}

// MARK: - TouchObserver

/// A non-interfering gesture recognizer that just reports the touch stream.
private final class TouchObserver: UIGestureRecognizer {
    var began: ((UITouch) -> Void)?
    var moved: ((UITouch, UIEvent) -> Void)?
    var ended: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let t = touches.first { began?(t) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let t = touches.first { moved?(t, event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        ended?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        ended?()
        state = .failed
    }
}

// MARK: - PreviewOverlay

private final class PreviewOverlay: UIView {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageView.contentMode = .topLeft
        imageView.layer.opacity = 0
        addSubview(imageView)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }
}
#endif
