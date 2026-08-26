import Foundation
import DeepSkyCore

public actor SessionStore {
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func create(manifest: SessionManifest) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let stamp = formatter.string(from: manifest.startedAt)
        let slug = manifest.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let dir = root.appendingPathComponent("\(stamp)-\(slug)-\(manifest.id)")

        let fm = FileManager.default
        for sub in ["frames", "darks", "thumbs"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub),
                                   withIntermediateDirectories: true)
        }
        // Write-once. Never mutated for the life of the session.
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("session.json"))
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
            .write(to: session.appendingPathComponent("completion.json"))
    }

    /// Discards a trailing partial line rather than throwing. A half-written
    /// record means the process died mid-append; the frames before it are
    /// still perfectly good.
    public nonisolated static func readFrames(at session: URL) throws -> [FrameRecord] {
        let url = session.appendingPathComponent("frames.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(FrameRecord.self, from: data)
            }
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
}
