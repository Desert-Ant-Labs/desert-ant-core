import Foundation

#if !os(WASI)
public struct RankingGolden: Decodable {
    public struct Case: Decodable {
        public struct Rank: Decodable {
            public let label: String
            public let score: Double
        }
        public let text: String
        public let ranks: [Rank]
    }

    public let tolerance: Double
    public let cases: [Case]
}
#endif
