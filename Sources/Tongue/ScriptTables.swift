import Foundation

// UAX#24 script routing, GENERATED from the Python reference by
// scripts/gen_swift_tables.py. Do not hand-edit: regenerate instead, so the SDK
// and the reference cannot drift.

public enum Script: String, Sendable, CaseIterable {
    case arabic = "Arabic"
    case armenian = "Armenian"
    case bengali = "Bengali"
    case cherokee = "Cherokee"
    case cyrillic = "Cyrillic"
    case devanagari = "Devanagari"
    case ethiopic = "Ethiopic"
    case georgian = "Georgian"
    case greek = "Greek"
    case gujarati = "Gujarati"
    case gurmukhi = "Gurmukhi"
    case han = "Han"
    case hangul = "Hangul"
    case hebrew = "Hebrew"
    case hiragana = "Hiragana"
    case japanese = "Japanese"
    case kannada = "Kannada"
    case katakana = "Katakana"
    case khmer = "Khmer"
    case lao = "Lao"
    case latin = "Latin"
    case malayalam = "Malayalam"
    case mongolian = "Mongolian"
    case myanmar = "Myanmar"
    case oriya = "Oriya"
    case sinhala = "Sinhala"
    case syriac = "Syriac"
    case tamil = "Tamil"
    case telugu = "Telugu"
    case thaana = "Thaana"
    case thai = "Thai"
    case tibetan = "Tibetan"
}

enum ScriptTables {
    // Sorted, non-overlapping ranges; looked up by binary search.
    static let ranges: [(UInt32, UInt32, Script)] = [
        (0x0041, 0x005A, .latin),
        (0x0061, 0x007A, .latin),
        (0x00C0, 0x024F, .latin),
        (0x0370, 0x03FF, .greek),
        (0x0400, 0x052F, .cyrillic),
        (0x0530, 0x058F, .armenian),
        (0x0590, 0x05FF, .hebrew),
        (0x0600, 0x06FF, .arabic),
        (0x0700, 0x074F, .syriac),
        (0x0750, 0x077F, .arabic),
        (0x0780, 0x07BF, .thaana),
        (0x08A0, 0x08FF, .arabic),
        (0x0900, 0x097F, .devanagari),
        (0x0980, 0x09FF, .bengali),
        (0x0A00, 0x0A7F, .gurmukhi),
        (0x0A80, 0x0AFF, .gujarati),
        (0x0B00, 0x0B7F, .oriya),
        (0x0B80, 0x0BFF, .tamil),
        (0x0C00, 0x0C7F, .telugu),
        (0x0C80, 0x0CFF, .kannada),
        (0x0D00, 0x0D7F, .malayalam),
        (0x0D80, 0x0DFF, .sinhala),
        (0x0E00, 0x0E7F, .thai),
        (0x0E80, 0x0EFF, .lao),
        (0x0F00, 0x0FFF, .tibetan),
        (0x1000, 0x109F, .myanmar),
        (0x10A0, 0x10FF, .georgian),
        (0x1100, 0x11FF, .hangul),
        (0x1200, 0x137F, .ethiopic),
        (0x13A0, 0x13FF, .cherokee),
        (0x1780, 0x17FF, .khmer),
        (0x1800, 0x18AF, .mongolian),
        (0x1F00, 0x1FFF, .greek),
        (0x2D00, 0x2D2F, .georgian),
        (0x2DE0, 0x2DFF, .cyrillic),
        (0x3040, 0x309F, .hiragana),
        (0x30A0, 0x30FF, .katakana),
        (0x3130, 0x318F, .hangul),
        (0x31F0, 0x31FF, .katakana),
        (0x3400, 0x4DBF, .han),
        (0x4E00, 0x9FFF, .han),
        (0xA640, 0xA69F, .cyrillic),
        (0xAB70, 0xABBF, .cherokee),
        (0xAC00, 0xD7AF, .hangul),
        (0xF900, 0xFAFF, .han),
        (0xFB50, 0xFDFF, .arabic),
        (0xFE70, 0xFEFF, .arabic),
    ]

    // Scripts only one language uses: presence settles the answer outright.
    static let decisive: [Script: String] = [
        .armenian: "hy",
        .cherokee: "chr",
        .ethiopic: "am",
        .georgian: "ka",
        .greek: "el",
        .gujarati: "gu",
        .gurmukhi: "pa",
        .han: "zh",
        .hangul: "ko",
        .hebrew: "he",
        .hiragana: "ja",
        .kannada: "kn",
        .katakana: "ja",
        .khmer: "km",
        .lao: "lo",
        .malayalam: "ml",
        .mongolian: "mn",
        .myanmar: "my",
        .oriya: "or",
        .sinhala: "si",
        .syriac: "syr",
        .tamil: "ta",
        .telugu: "te",
        .thaana: "dv",
        .thai: "th",
        .tibetan: "bo",
    ]

    // Scripts several languages share: presence narrows the candidate set.
    static let narrowing: [Script: [String]] = [
        .arabic: ["ar", "fa", "ur", "ug"],
        .bengali: ["bn", "as"],
        .cyrillic: ["ru", "uk", "bg", "sr", "mk", "be", "kk", "ky"],
        .devanagari: ["hi", "mr", "ne"],
    ]
}
