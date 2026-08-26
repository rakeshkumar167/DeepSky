import Foundation
import DeepSkyCore

public actor SessionStore {
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func create(manifest: SessionManifest) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let stamp = formatter.string(from: manifest.startedAt)
        let slug = Self.sanitize(manifest.name.lowercased().replacingOccurrences(of: " ", with: "-"))
        let dir = root.appendingPathComponent("\(stamp)-\(slug)-\(manifest.id)")

        let fm = FileManager.default
        for sub in ["frames", "darks", "thumbs"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub),
                                   withIntermediateDirectories: true)
        }
        // Write-once. Never mutated for the life of the session.
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
        fm.createFile(atPath: dir.appendingPathComponent("frames.jsonl").path, contents: nil)
        return dir
    }

    /// Appends one JSON object plus a newline, then fsyncs. Append-only is
    /// what makes an interrupted session recoverable (spec §39).
    public func append(_ record: FrameRecord, to session: URL) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)

        let url = session.appendingPathComponent("frames.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func complete(_ completion: SessionCompletion, at session: URL) throws {
        try encoder.encode(completion)
            .write(to: session.appendingPathComponent("completion.json"), options: .atomic)
    }

    /// Discards a trailing partial line rather than throwing. A half-written
    /// record means the process died mid-append; the frames before it are
    /// still perfectly good. Any other read or decode failure propagates —
    /// the recovery flow's Discard action trusts this count, so silently
    /// returning a short (or empty) list here would be a setup for
    /// user-initiated data loss.
    public nonisolated static func readFrames(at session: URL) throws -> [FrameRecord] {
        let url = session.appendingPathComponent("frames.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var records: [FrameRecord] = []
        records.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            do {
                records.append(try decoder.decode(FrameRecord.self, from: Data(line.utf8)))
            } catch {
                // A decode failure is only sanctioned on the final line
                // (a torn trailing write). Anywhere else it is real
                // corruption and must not be silently dropped.
                guard offset == lines.count - 1 else { throw error }
            }
        }
        return records
    }

    /// A session directory without completion.json is by definition incomplete.
    public func incompleteSessions() throws -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
            else { return false }
            let hasManifest = fm.fileExists(atPath: dir.appendingPathComponent("session.json").path)
            let hasCompletion = fm.fileExists(atPath: dir.appendingPathComponent("completion.json").path)
            return hasManifest && !hasCompletion
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A session's directory name is derived from `manifest.name`, which a
    /// later plan's UI populates from user input. Restricting the slug to a
    /// safe character set keeps `appendingPathComponent` from being able to
    /// escape `root` via `/` or `..` segments.
    private static let allowedSlugCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    private static func sanitize(_ slug: String) -> String {
        String(slug.unicodeScalars.map { allowedSlugCharacters.contains($0) ? Character($0) : "-" })
    }
}
