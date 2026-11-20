import Foundation
import Testing
@testable import Shapes

/// The input built from the meta's channel list: a model without time reads
/// five values per point, and a channel the meta marks as zero is fed 0.
struct ChannelTests {
    static let drawing: [[InkPoint]] = [
        (0..<20).map { InkPoint(x: Double($0) * 5, y: Double($0 % 4) * 3, t: Double($0) * 16) },
        (0..<12).map { InkPoint(x: 40, y: Double($0) * 6 - 20, t: 900 + Double($0) * 25) },
    ]

    @Test func withoutTimeEachPointIsTheFirstFiveValues() throws {
        let six = try #require(Ink.prepare(Self.drawing, count: 64, maxStrokes: 8))
        let five = try #require(Ink.prepare(Self.drawing, count: 64, maxStrokes: 8,
                                            channels: ["x", "y", "dx", "dy", "start"]))
        #expect(six.x.count == 64 * 6 && five.x.count == 64 * 5)
        for i in 0..<64 { #expect(Array(five.x[(5 * i)..<(5 * i + 5)]) == Array(six.x[(6 * i)..<(6 * i + 5)])) }
        #expect(five.stroke == six.stroke)
    }

    @Test func aZeroChannelIsFedZero() throws {
        let six = try #require(Ink.prepare(Self.drawing, count: 64, maxStrokes: 8))
        let zeroed = try #require(Ink.prepare(Self.drawing, count: 64, maxStrokes: 8,
                                              channels: Ink.channels, zero: ["log1p_dt"]))
        #expect(six.x.enumerated().contains { $0.offset % 6 == 5 && $0.element > 0 })
        for i in 0..<64 {
            #expect(zeroed.x[6 * i + 5] == 0)
            #expect(Array(zeroed.x[(6 * i)..<(6 * i + 5)]) == Array(six.x[(6 * i)..<(6 * i + 5)]))
        }
    }

    @Test func anUnknownChannelIsRefused() {
        #expect(Ink.prepare(Self.drawing, count: 64, maxStrokes: 8, channels: ["x", "y", "pressure"]) == nil)
    }

    @Test func theMetaListsTheChannels() throws {
        func meta(_ x: String) throws -> ShapeMeta {
            try ShapeMeta(json: """
            {"kinds": ["plus", "none"], "reject_kinds": ["none"], "n_points": 256, "max_strokes": 32,
             "input": {"x": \(x)}, "outputs": {"kind_logits": [1, 2], "numbers": [1, 8]},
             "numbers": {"kinds": {}}, "resid_gates": {}}
            """)
        }
        let zeroed = try meta(#"{"channels": ["x", "y", "dx", "dy", "start", "log1p_dt"], "zero_channels": ["log1p_dt"]}"#)
        #expect(zeroed.channels == Ink.channels && zeroed.zeroChannels == ["log1p_dt"])
        let five = try meta(#"{"channels": ["x", "y", "dx", "dy", "start"]}"#)
        #expect(five.channels == ["x", "y", "dx", "dy", "start"] && five.zeroChannels.isEmpty)
    }

    /// The order the training code puts a plus's numbers in: the more level
    /// stroke first from its left end, the more upright one from its upper end.
    @Test func aPlusComesInTheTrainingOrder() {
        let upright = [0.1, 0.4, 0.0, -0.4], level = [0.4, 0.05, -0.4, 0.0]
        let p = Numbers.canonical("plus", upright + level)
        #expect(p == [-0.4, 0.0, 0.4, 0.05, 0.0, -0.4, 0.1, 0.4])
    }
}
