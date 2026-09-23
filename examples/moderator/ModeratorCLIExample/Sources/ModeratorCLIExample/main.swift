import Foundation
import Moderator

// Score each image file for NSFW content.
//
//   swift run ModeratorCLIExample photo.jpg other.png
//   MODERATOR_MODEL_DIR=/path/to/model swift run ModeratorCLIExample photo.jpg

let paths = CommandLine.arguments.dropFirst()
guard !paths.isEmpty else {
    print("usage: ModeratorCLIExample <image> [<image> ...]")
    exit(2)
}

// Downloads the model on first use and caches it, unless pointed at a folder that
// already holds it.
let moderator = Moderator(directory: ProcessInfo.processInfo.environment["MODERATOR_MODEL_DIR"])

for path in paths {
    let url = URL(fileURLWithPath: path)
    let start = Date()
    let result = try await moderator.analyze(contentsOf: url)
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let r = result.regions
    print(String(format: "%@  score %.3f  %@  (%d ms)", url.lastPathComponent, result.score,
                 result.isNSFW ? "NSFW" : "safe", ms))
    print(String(format: "  nipples %.2f  genitals %.2f  buttocks %.2f  nude %.2f  sexAct %.2f",
                 r.nipples, r.genitals, r.buttocks, r.nude, r.sexAct))
}
