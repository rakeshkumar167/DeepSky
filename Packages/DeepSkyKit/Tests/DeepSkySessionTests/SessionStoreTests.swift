import Testing
import Foundation
import DeepSkyCore
@testable import DeepSkySession

private func makeManifest() -> SessionManifest {
    SessionManifest(
        id: UUID().uuidString, name: "Milky Way",
        startedAt: Date(timeIntervalSince1970: 776000000),
        plan: CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                          intervalSeconds: 0.05, frameCount: 60),
        capabilities: DeviceCapabilities(deviceModel: "iPhone17,1", osVersion: "26.3",
                                         supportsAppleProRAW: true, lenses: [],
                                         probedAt: Date(timeIntervalSince1970: 776000000)))
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
