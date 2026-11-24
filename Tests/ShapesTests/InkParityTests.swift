import Foundation
import Testing
@testable import Shapes

/// The Swift input steps and number decoding against the Python implementation
/// the model was trained with (weights v2.1.0: five numbers per point, no time).
///
/// `Tests/Fixtures/shapes-v2-parity.json` holds 21 drawings of in-house generated
/// ink, one of every kind with a template and four cut to half their points: the
/// strokes as an app hands them over, the model input the Python code prepares,
/// the model's outputs in torch, through Core ML on the CPU and through the
/// LiteRT build on the CPU, the sidecar the
/// published build carries, the top kind's numbers decoded, in the drawing's
/// frame and on the canvas, and the template fit from them (40 steps).
struct InkParityTests {
    struct Case: @unchecked Sendable {
        let name: String
        let label: String
        let strokes: [[InkPoint]]
        let x: [Double]
        let stroke: [Int32]
        let coremlLogits: [Float]
        let coremlNumbers: [Float]
        /// The LiteRT build's logits on the CPU, the reference where the SDK
        /// runs LiteRT (Android, Linux, Windows, the web).
        let litertLogits: [Float]?
        let top: String
        let decoded: [String: Any]?
        let fit: [String: Any]?

        var timedStrokes: [Stroke] {
            strokes.map { stroke in
                Stroke(points: stroke.map { Point(x: $0.x, y: $0.y) }, times: stroke.map(\.t))
            }
        }
    }

    nonisolated(unsafe) static let fixture: (meta: String, cases: [Case])? = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/shapes-v2-parity.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["meta"], let raw = json["cases"] as? [[String: Any]],
              let metaData = try? JSONSerialization.data(withJSONObject: meta) else { return nil }
        let cases = raw.map { c in
            let coreml = c["coreml_cpu"] as! [String: Any]
            return Case(
                name: c["name"] as! String, label: c["label"] as! String,
                strokes: (c["strokes"] as! [[[Double]]]).map { $0.map { InkPoint(x: $0[0], y: $0[1], t: $0[2]) } },
                x: (c["x"] as! [[Double]]).flatMap { $0 },
                stroke: (c["stroke"] as! [Int]).map(Int32.init),
                coremlLogits: (coreml["kind_logits"] as! [Double]).map(Float.init),
                coremlNumbers: (coreml["numbers"] as! [Double]).map(Float.init),
                litertLogits: ((c["litert_cpu"] as? [String: Any])?["kind_logits"] as? [Double])?.map(Float.init),
                top: c["top"] as! String, decoded: c["decoded"] as? [String: Any], fit: c["fit"] as? [String: Any])
        }
        return (String(decoding: metaData, as: UTF8.self), cases)
    }()

    static var cases: [Case] { fixture?.cases ?? [] }
    static var meta: ShapeMeta? { fixture.flatMap { try? ShapeMeta(json: $0.meta) } }

    // A wasm run can't read the fixture from the repo, so on wasm the parity
    // tests below run over an empty list.
    #if !os(WASI)
    @Test func fixtureIsPresent() throws {
        #expect(Self.cases.count >= 20)
        let meta = try #require(Self.meta)
        #expect(meta.kinds.count == 18 && meta.pointCount == 256 && meta.numbersWidth == 125)
        #expect(meta.rejects == [meta.kinds.firstIndex(of: "none")!])
    }
    #endif

    /// The model input within 1e-5 of the Python implementation's, and the same
    /// stroke indices.
    @Test(arguments: cases.map(\.name))
    func inputMatchesTheReference(name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let meta = try #require(Self.meta)
        let got = try #require(Ink.prepare(c.strokes, count: meta.pointCount, maxStrokes: meta.maxStrokes,
                                           channels: meta.channels, zero: meta.zeroChannels))
        #expect(got.stroke == c.stroke, "\(name): stroke indices")
        var worst = 0.0, at = 0
        for (i, v) in c.x.enumerated() where abs(Double(got.x[i]) - v) > worst {
            worst = abs(Double(got.x[i]) - v); at = i
        }
        let width = meta.channels.count
        #expect(worst <= 1e-5, "\(name): input off by \(worst) at point \(at / width), channel \(at % width)")
    }

    /// The top kind's numbers decoded from the Core ML outputs as the Python
    /// implementation decodes them: in the drawing's frame within 1e-5, and on
    /// the canvas within 1e-4 of the drawing's size.
    @Test(arguments: cases.filter { $0.decoded != nil }.map(\.name))
    func numbersMatchTheReference(name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let meta = try #require(Self.meta)
        let ref = try #require(c.decoded)
        let k = try #require(meta.numbers[c.top])
        let frame = Numbers.decode(c.top, Array(c.coremlNumbers[k.offset..<(k.offset + k.outputs.count)]), k)
        let refFrame = ref["frame"] as! [Double]
        #expect(zip(frame, refFrame).allSatisfy { abs($0 - $1) <= 1e-5 }, "\(name): frame \(frame) vs \(refFrame)")
        let prepared = try #require(Ink.prepare(c.strokes, count: meta.pointCount, maxStrokes: meta.maxStrokes,
                                                channels: meta.channels, zero: meta.zeroChannels))
        let center = ref["centre"] as! [Double], scale = ref["scale"] as! Double
        #expect(abs(prepared.center.x - center[0]) <= 1e-6 && abs(prepared.center.y - center[1]) <= 1e-6
                && abs(prepared.scale - scale) <= 1e-6, "\(name): frame")
        let canvas = Numbers.toCanvas(frame, names: k.names, center: prepared.center, scale: prepared.scale)
        let refCanvas = ref["canvas"] as! [Double]
        #expect(zip(canvas, refCanvas).allSatisfy { abs($0 - $1) <= 1e-4 * scale }, "\(name): canvas \(canvas) vs \(refCanvas)")
    }

    #if !os(WASI)
    /// The top kind of the Core ML outputs is the Python implementation's.
    @Test func topKindIsTheReference() throws {
        let meta = try #require(Self.meta)
        for c in Self.cases {
            var top = 0
            for i in c.coremlLogits.indices where c.coremlLogits[i] > c.coremlLogits[top] { top = i }
            #expect(meta.kinds[top] == c.top, "\(c.name)")
        }
    }
    #endif

    /// The template outlines match the Python implementation's: the residual of
    /// the model's numbers and of the Python fit's numbers within 1e-5.
    @Test(arguments: cases.filter { $0.fit != nil }.map(\.name))
    func outlineMatchesTheReference(name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let ref = try #require(c.fit), decoded = try #require(c.decoded)
        let pts = try #require(Ink.framePoints(c.strokes, count: TemplateFit.pointCount, maxStrokes: 64))
        let start = TemplateFit.residual(c.top, decoded["frame"] as! [Double], pts)
        let refined = TemplateFit.residual(c.top, ref["refined"] as! [Double], pts)
        #expect(abs(start - (ref["start_residual"] as! Double)) <= 1e-5, "\(name): residual at the model's numbers \(start)")
        #expect(abs(refined - (ref["refined_residual"] as! Double)) <= 1e-5, "\(name): residual at the Python fit \(refined)")
    }

    /// The Swift fit from the model's numbers lowers the residual and lands
    /// within 0.002 of the Python fit's (autograd there, central differences here).
    @Test(arguments: cases.filter { $0.fit != nil }.map(\.name))
    func fitReachesTheReference(name: String) throws {
        let c = try #require(Self.cases.first { $0.name == name })
        let ref = try #require(c.fit), decoded = try #require(c.decoded)
        let pts = try #require(Ink.framePoints(c.strokes, count: TemplateFit.pointCount, maxStrokes: 64))
        let fit = TemplateFit.fit(c.top, points: pts, from: decoded["frame"] as! [Double])
        let start = ref["start_residual"] as! Double, target = ref["refined_residual"] as! Double
        #expect(fit.residual < start && fit.residual <= target + 0.002,
                "\(name): \(start) to \(fit.residual), Python \(target)")
    }
}
