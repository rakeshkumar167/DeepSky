import Testing
import Foundation
import DeepSkyCore
@testable import DeepSkySession

private func makeSettings() -> CaptureSettings {
    CaptureSettings(lensIndex: 0, iso: 1600, exposure: ShutterSpeed(seconds: 1.0),
                    lensPosition: 1.0, whiteBalanceKelvin: 3900, exposureBias: 0)
}

private func makeManifest(name: String = "Milky Way") -> SessionManifest {
    SessionManifest(
        id: UUID().uuidString, name: name,
        startedAt: Date(timeIntervalSince1970: 776000000),
        plan: CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                          intervalSeconds: 0.05, frameCount: 60),
        capabilities: DeviceCapabilities(deviceModel: "iPhone17,1", osVersion: "26.3",
                                         supportsAppleProRAW: true, lenses: [],
                                         probedAt: Date(timeIntervalSince1970: 776000000)),
        settings: makeSettings())
}

private func makeRecord(_ i: Int) -> FrameRecord {
    FrameRecord(index: i, file: "frames/frame_\(i).dng",
                capturedAt: Date(timeIntervalSince1970: 776000000 + Double(i)),
                iso: 1600, exposureSeconds: 1.0, lensPosition: 1.0,
                whiteBalanceKelvin: 3900, bytes: 100, thermalState: .nominal,
                stability: StabilityReading(rmsAngularRateRadPerSec: 0.001,
                                            predictedDriftPixels: 0.2, band: .excellent),
                flags: [], isDark: false)
}

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepsky-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func createsSessionDirectoryStructure() async throws {
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("session.json").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("frames").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("darks").path))
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("thumbs").path))
    #expect(!fm.fileExists(atPath: dir.appendingPathComponent("completion.json").path))
}

@Test func appendsOneLinePerFrame() async throws {
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    for i in 1...3 { try await store.append(makeRecord(i), to: dir) }

    let text = try String(contentsOf: dir.appendingPathComponent("frames.jsonl"), encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 3)

    let records = try SessionStore.readFrames(at: dir)
    #expect(records.map(\.index) == [1, 2, 3])
}

@Test func recoversFromTruncatedFinalLine() async throws {
    // Simulates power loss mid-write: the last JSON object is cut in half.
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    for i in 1...5 { try await store.append(makeRecord(i), to: dir) }

    let jsonl = dir.appendingPathComponent("frames.jsonl")
    var text = try String(contentsOf: jsonl, encoding: .utf8)
    text = String(text.dropLast(40))   // shear off part of record 5
    try text.write(to: jsonl, atomically: true, encoding: .utf8)

    let records = try SessionStore.readFrames(at: dir)
    #expect(records.count == 4)
    #expect(records.map(\.index) == [1, 2, 3, 4])
}

@Test func completionMarkerDistinguishesFinishedSessions() async throws {
    let root = tempRoot()
    let store = SessionStore(root: root)
    let finished = try await store.create(manifest: makeManifest())
    let abandoned = try await store.create(manifest: makeManifest())

    try await store.append(makeRecord(1), to: finished)
    try await store.complete(SessionCompletion(endedAt: Date(), framesWritten: 1,
                                               framesFlagged: 0, darksWritten: 0), at: finished)

    let incomplete = try await store.incompleteSessions()
    #expect(incomplete.count == 1)
    #expect(incomplete[0].lastPathComponent == abandoned.lastPathComponent)
}

@Test func neverRewritesSessionManifest() async throws {
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    let manifestURL = dir.appendingPathComponent("session.json")
    let before = try Data(contentsOf: manifestURL)

    for i in 1...3 { try await store.append(makeRecord(i), to: dir) }
    try await store.complete(SessionCompletion(endedAt: Date(), framesWritten: 3,
                                               framesFlagged: 0, darksWritten: 0), at: dir)

    let after = try Data(contentsOf: manifestURL)
    #expect(before == after)
}

@Test func middleLineCorruptionThrowsRatherThanSilentlyTruncating() async throws {
    // Only a *trailing* torn line is a sanctioned recovery case. Corruption
    // in the middle of the file is real data loss and the recovery flow's
    // Discard action trusts this count, so it must throw, not silently
    // return a short list.
    let store = SessionStore(root: tempRoot())
    let dir = try await store.create(manifest: makeManifest())
    for i in 1...5 { try await store.append(makeRecord(i), to: dir) }

    let jsonl = dir.appendingPathComponent("frames.jsonl")
    let text = try String(contentsOf: jsonl, encoding: .utf8)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    #expect(lines.count == 5)
    lines[2] = "{this is not valid json"   // corrupt record 3 — not the last line
    let corrupted = lines.joined(separator: "\n") + "\n"
    try corrupted.write(to: jsonl, atomically: true, encoding: .utf8)

    #expect(throws: (any Error).self) {
        _ = try SessionStore.readFrames(at: dir)
    }
}

@Test func sessionManifestRoundTripsThroughDiskIncludingDatesAndSettings() async throws {
    let store = SessionStore(root: tempRoot())
    let original = makeManifest()
    let dir = try await store.create(manifest: original)

    let data = try Data(contentsOf: dir.appendingPathComponent("session.json"))
    // session.json is written with ISO-8601 date strings (spec), not the
    // bare-Double default — the decoder here must be configured to match.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionManifest.self, from: data)

    #expect(decoded == original)
    #expect(decoded.startedAt == original.startedAt)
    #expect(decoded.settings == original.settings)
}

@Test func sanitizesUnsafeCharactersInSessionNameToStayInsideRoot() async throws {
    // A later plan's UI populates `manifest.name` from user input; a name
    // containing path-traversal segments must not be able to escape root.
    let root = tempRoot()
    let store = SessionStore(root: root)
    let evil = makeManifest(name: "../../evil")
    let dir = try await store.create(manifest: evil)

    #expect(dir.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    #expect(!dir.lastPathComponent.contains(".."))
    #expect(!dir.lastPathComponent.contains("/"))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path))
}
