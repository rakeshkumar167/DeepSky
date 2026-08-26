import Foundation

/// Locating the real exported session, and deciding what it can validate.
///
/// Real DNGs are ~19MB each and are never committed, so every test touching
/// them is gated on a `.enabled(if:)` trait. Note `#require` FAILS a test in
/// Swift Testing rather than skipping it — gating has to happen in a trait, or
/// a machine without the session gets failures instead of skips.
enum SampleSession {
    /// Finds the most recent exported session in ~/Downloads.
    ///
    /// Matches on structure (a `frames/` directory holding DNGs) rather than on
    /// the folder name — sessions get renamed when they are exported, and
    /// pattern-matching the name silently found nothing when that happened.
    static func frames() -> [URL] {
        // Explicit override wins. Directory mtime is an unreliable way to pick
        // "the newest session" — reading a folder can update it, which silently
        // analysed the wrong session once.
        if let path = ProcessInfo.processInfo.environment["DEEPSKY_SESSION"] {
            let dir = URL(fileURLWithPath: path).appendingPathComponent("frames")
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
                return contents.filter { $0.pathExtension.lowercased() == "dng" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            return []
        }

        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        let candidates = entries.compactMap { dir -> (URL, Date, [URL])? in
            let framesDir = dir.appendingPathComponent("frames")
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: framesDir, includingPropertiesForKeys: nil) else { return nil }
            let dngs = contents.filter { $0.pathExtension.lowercased() == "dng" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !dngs.isEmpty else { return nil }
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (dir, modified, dngs)
        }

        return candidates.max { $0.1 < $1.1 }?.2 ?? []
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
