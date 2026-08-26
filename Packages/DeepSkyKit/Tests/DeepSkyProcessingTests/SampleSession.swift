import Foundation

/// Locating the real exported session, and deciding what it can validate.
///
/// Real DNGs are ~19MB each and are never committed, so every test touching
/// them is gated on a `.enabled(if:)` trait. Note `#require` FAILS a test in
/// Swift Testing rather than skipping it — gating has to happen in a trait, or
/// a machine without the session gets failures instead of skips.
enum SampleSession {
    static func frames() -> [URL] {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: nil) else { return [] }
        for dir in entries where dir.lastPathComponent.contains("-astro-") {
            let framesDir = dir.appendingPathComponent("frames")
            if let dngs = try? FileManager.default.contentsOfDirectory(
                at: framesDir, includingPropertiesForKeys: nil) {
                return dngs.filter { $0.pathExtension.lowercased() == "dng" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        return []
    }

    static func exists() -> Bool { frames().count >= 2 }
    static func hasAtLeastThreeFrames() -> Bool { frames().count >= 3 }

    /// Fraction of frames the capture flagged for movement, from `frames.jsonl`.
    static func motionFlaggedFraction() -> Double? {
        guard let first = frames().first else { return nil }
        let manifest = first.deletingLastPathComponent()   // frames/
            .deletingLastPathComponent()                   // session/
            .appendingPathComponent("frames.jsonl")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return nil }
        return Double(lines.filter { $0.contains("\"motion\"") }.count) / Double(lines.count)
    }

    /// Whether the session can validate UNALIGNED stacking at all.
    ///
    /// The noise check measures spatial σ over a patch, which only means
    /// "noise" when the patch is flat sky and the frames are aligned. With no
    /// alignment stage, a session whose frames moved smears scene structure
    /// into the patch and σ goes UP — the first real session measured 0.72×,
    /// worse than a single frame, with all five frames flagged and true drift
    /// of 37–75px each.
    static func isStableEnoughForUnalignedStacking() -> Bool {
        guard hasAtLeastThreeFrames(), let flagged = motionFlaggedFraction() else { return false }
        return flagged <= 0.2
    }
}
