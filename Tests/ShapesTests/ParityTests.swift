import Foundation
import Testing
@testable import Shapes

/// The Swift preprocessing and fitters against the Python implementation the
/// model was trained and evaluated with.
///
/// `Tests/Fixtures/shapes-parity.json` holds 51 strokes: generated strokes of
/// every kind, and real strokes from the $1 gesture set and Quick, Draw!. For
/// each stroke the file holds the Python model input, the trained model's
/// outputs, and the Python fit of the stroke's labeled kind.
struct ParityTests {
    struct Case {
        let name: String
        let label: String
        let points: [Point]
        let modelInput: [[Double]]
        let probs: [Double]
        let head: [Float]
        let fit: [String: Any]?
    }

    // Read-only after loading. `fit` is untyped JSON, which isn't Sendable.
    nonisolated(unsafe) static let cases: [Case] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/shapes-parity.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["cases"] as? [[String: Any]] else { return [] }
        return raw.map { c in
            Case(name: c["name"] as! String, label: c["label"] as! String,
                 points: (c["points"] as! [[Double]]).map { Point(x: $0[0], y: $0[1]) },
                 modelInput: c["model_input"] as! [[Double]],
                 probs: c["probs"] as! [Double],
                 head: (c["head"] as! [Double]).map(Float.init),
                 fit: c["fit"] as? [String: Any])
        }
    }()

    static func p(_ any: Any?) -> Point {
        let a = any as! [Double]
        return Point(x: a[0], y: a[1])
    }

    static func d(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func size(_ pts: [Point]) -> Double {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!, 1e-9)
    }

    // A wasm run can't read the fixture from the repo, so on wasm the parity
    // tests below run over an empty list.
    #if !os(WASI)
    @Test func fixtureIsPresent() {
        #expect(Self.cases.count >= 40)
    }
    #endif

    @Test func modelInputMatchesTheReference() {
        for c in Self.cases {
            let got = Preprocess.modelInput(c.points, count: 128)
            var worst = 0.0
            for (i, v) in c.modelInput.enumerated() {
                worst = max(worst, abs(Double(got[2 * i]) - v[0]), abs(Double(got[2 * i + 1]) - v[1]))
            }
            #expect(worst <= 1e-5, "\(c.name): model input off by \(worst)")
        }
    }

    /// Each fitter matches the Python fit of the stroke's labeled kind, given
    /// the same arrowhead probabilities: parameters within 0.5% of the stroke's
    /// size, and residuals within 0.0005.
    @Test(arguments: cases.filter { $0.fit != nil }.map(\.name))
    func fitMatchesTheReference(name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let ref = try #require(c.fit)
        let kind = try #require(Shape.Kind(rawValue: c.label))
        let got = Fitter.fit(kind, points: c.points, head: c.head)
        let tol = 0.005 * Self.size(c.points)
        let params = ref["params"] as! [String: Any]
        #expect(abs(got.residual - (ref["residual"] as! Double)) <= 5e-4, "\(name): residual \(got.residual) vs \(ref["residual"]!)")
        func close(_ a: Point, _ b: Point, _ what: String) {
            #expect(Self.d(a, b) <= tol, "\(name): \(what) \(a) vs \(b)")
        }
        func closeAll(_ a: [Point], _ b: [Point], _ what: String) {
            #expect(a.count == b.count, "\(name): \(what) count \(a.count) vs \(b.count)")
            for (x, y) in zip(a, b) { close(x, y, what) }
        }
        switch (got.shape, ref["kind"] as! String) {
        case let (.line(a, b), "line"):
            close(a, Self.p(params["from"]), "from"); close(b, Self.p(params["to"]), "to")
        case let (.curve(a, c1, c2, b), "curve"):
            close(a, Self.p(params["from"]), "from"); close(c1, Self.p(params["c1"]), "c1")
            close(c2, Self.p(params["c2"]), "c2"); close(b, Self.p(params["to"]), "to")
        case let (.arrow(_, _, _, _, start, end), "arrow"):
            let heads = (params["heads"] as! [[String: Any]])
            let refEnds = Set(heads.map { $0["at"] as! String })
            #expect(start == refEnds.contains("start") && end == refEnds.contains("end"), "\(name): heads")
            let refShaft = got.outline  // the tip positions are the shaft's ends
            for h in heads {
                let tip = Self.p(h["tip"])
                let mine = h["at"] as! String == "end" ? refShaft[refShaft.count - 1] : refShaft[0]
                close(Point(x: mine.x, y: mine.y), tip, "tip")
            }
        case let (.ellipse(center, a, b, _), "ellipse"):
            close(center, Self.p(params["center"]), "center")
            #expect(abs(a - (params["semi_major"] as! Double)) <= tol && abs(b - (params["semi_minor"] as! Double)) <= tol, "\(name): axes")
        case let (.rectangle(corners), "rectangle"):
            closeAll(corners, (params["corners"] as! [[Double]]).map { Self.p($0) }, "corner")
        case let (.triangle(vs), "triangle"), let (.diamond(vs), "diamond"),
             let (.pentagon(vs), "pentagon"), let (.hexagon(vs), "hexagon"):
            closeAll(vs, (params["vertices"] as! [[Double]]).map { Self.p($0) }, "vertex")
        case let (.star(center, outer, inner, _, count), "star"):
            close(center, Self.p(params["center"]), "center")
            #expect(count == params["point_count"] as! Int, "\(name): points")
            #expect(abs(outer - (params["outer_radius"] as! Double)) <= tol && abs(inner - (params["inner_radius"] as! Double)) <= tol, "\(name): radii")
        case let (.heart(center, w, h), "heart"):
            close(center, Self.p(params["center"]), "center")
            #expect(abs(w - (params["width"] as! Double)) <= tol && abs(h - (params["height"] as! Double)) <= tol, "\(name): size")
        case (.cloud, "cloud"), (.scribble, "scribble"):
            break  // outline-defined: the residual above holds them
        default:
            Issue.record("\(name): fitted \(got.shape.kind), reference \(ref["kind"]!)")
        }
    }
}
