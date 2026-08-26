import Testing
import Foundation
import Synchronization
import DeepSkyCore
import DeepSkyCapture
import DeepSkySynthetic
@testable import DeepSkySession

private struct StubSensor: EnvironmentSensor {
    var thermal: ThermalState = .nominal
    var free: Int64 = 100_000_000_000
    var rate: Double = 0.0001
    func thermalState() -> ThermalState { thermal }
    func freeBytes() -> Int64 { free }
    func rmsAngularRate() -> Double { rate }
}

/// Reports `.critical` on exactly its first `thermalState()` call, and
/// `.nominal` on every call after that. `EnvironmentSensor` is `Sendable`
/// and its methods are synchronous, so the call counter needs real
/// synchronisation — `Mutex` rather than a plain `var`.
///
/// This exists to make the `captureLoop:` label test-discriminating (see
/// `stopsPermanentlyOnFirstCriticalDecisionRatherThanRetrying` below): a
/// fixed always-`.critical` sensor cannot tell a correct labelled `break`
/// from a buggy bare `break`, because `CapturePolicy.decide` would just
/// return `.stop` again on every subsequent iteration either way.
private final class OneShotCriticalSensor: EnvironmentSensor, Sendable {
    private let callCount = Mutex(0)

    func thermalState() -> ThermalState {
        callCount.withLock { count in
            count += 1
            return count == 1 ? .critical : .nominal
        }
    }
    func freeBytes() -> Int64 { 100_000_000_000 }
    func rmsAngularRate() -> Double { 0.0001 }
}

private func caps() -> DeviceCapabilities {
    let format = FormatCapability(width: 4032, height: 3024,
                                  minExposureSeconds: 0.000015, maxExposureSeconds: 1.0,
                                  minISO: 55, maxISO: 12288,
                                  horizontalFieldOfViewDegrees: 68,
                                  maxPhotoDimensions: [[4032, 3024]], rawPixelFormats: ["bgg4"])
    return DeviceCapabilities(deviceModel: "Synthetic", osVersion: "26.3",
                              supportsAppleProRAW: true,
                              lenses: [LensCapability(deviceType: "wide", localizedName: "Wide",
                                                      focalLengthEquivalent: 24, formats: [format])],
                              probedAt: Date(timeIntervalSince1970: 776000000))
}

private func stdSettings() -> CaptureSettings {
    CaptureSettings(lensIndex: 0, iso: 1600, exposure: ShutterSpeed(seconds: 1.0),
                    lensPosition: 1.0, whiteBalanceKelvin: 3900, exposureBias: 0)
}

/// Exposure beyond the format's 1.0s maximum — `camera.apply` rejects
/// this before any frame is captured.
private func rejectedSettings() -> CaptureSettings {
    CaptureSettings(lensIndex: 0, iso: 1600, exposure: ShutterSpeed(seconds: 5.0),
                    lensPosition: 1.0, whiteBalanceKelvin: 3900, exposureBias: 0)
}

private func manifest(frames: Int, settings: CaptureSettings = stdSettings()) -> SessionManifest {
    SessionManifest(id: UUID().uuidString, name: "Test",
                    startedAt: Date(timeIntervalSince1970: 776000000),
                    plan: CapturePlan(sensorExposure: ShutterSpeed(seconds: 1.0),
                                      intervalSeconds: 0.0, frameCount: frames),
                    capabilities: caps(), settings: settings)
}

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("deepsky-coord-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func runsCompleteSessionAndWritesEveryFrame() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    let completion = try await coordinator.run(manifest: manifest(frames: 10),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 10)

    let store = SessionStore(root: root)
    let incomplete = try await store.incompleteSessions()
    #expect(incomplete.isEmpty)   // completion.json was written
}

@Test func writesEachFrameToDiskWithMatchingManifestEntry() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())
    _ = try await coordinator.run(manifest: manifest(frames: 5),
                                  settings: stdSettings(), isDark: false)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let records = try SessionStore.readFrames(at: dir)
    #expect(records.count == 5)
    for record in records {
        let path = dir.appendingPathComponent(record.file)
        #expect(FileManager.default.fileExists(atPath: path.path))
        let size = try Data(contentsOf: path).count
        #expect(size == record.bytes)
    }
}

@Test func flagsShakyFramesButNeverDiscardsThem() async throws {
    // Spec D11: excessive motion is recorded, never acted on destructively.
    let root = tempRoot()
    var shaky = StubSensor()
    shaky.rate = 0.01   // far beyond the 1.5 px threshold at 1s
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: shaky)

    let completion = try await coordinator.run(manifest: manifest(frames: 6),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 6)      // nothing thrown away
    #expect(completion.framesFlagged == 6)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let records = try SessionStore.readFrames(at: dir)
    #expect(records.allSatisfy { $0.flags.contains(.motion) })
    #expect(records.allSatisfy { $0.stability.band == .poor })
}

@Test func stopsEarlyOnCriticalThermalAndStillCompletesSession() async throws {
    let root = tempRoot()
    var hot = StubSensor()
    hot.thermal = .critical
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: hot)

    let completion = try await coordinator.run(manifest: manifest(frames: 20),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 0)

    // Even an aborted session is finalised, not left dangling.
    let store = SessionStore(root: root)
    #expect(try await store.incompleteSessions().isEmpty)
}

@Test func stopsWhenStorageRunsOut() async throws {
    let root = tempRoot()
    var full = StubSensor()
    full.free = 1024   // nowhere near the 500 MB reserve
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: full)

    let completion = try await coordinator.run(manifest: manifest(frames: 20),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 0)
}

@Test func darkFramesGoToDarksDirectory() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    let completion = try await coordinator.run(manifest: manifest(frames: 4),
                                               settings: stdSettings(), isDark: true)
    #expect(completion.darksWritten == 4)
    #expect(completion.framesWritten == 0)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let records = try SessionStore.readFrames(at: dir)
    #expect(records.allSatisfy { $0.isDark })
    #expect(records.allSatisfy { $0.file.hasPrefix("darks/") })
}

@Test func stopsPermanentlyOnFirstCriticalDecisionRatherThanRetrying() async throws {
    // Discriminates the labelled `break captureLoop` from a bare `break`.
    // `OneShotCriticalSensor` reports `.critical` only on its very first
    // call, then `.nominal` forever after. With the correct labelled
    // break the loop exits for good on that first `.stop` decision, so
    // no frame is ever captured (framesWritten == 0). A bare `break`
    // would only exit the `switch`: the loop would move to iteration 2,
    // re-decide against the now-`.nominal` reading, reach `.proceed`,
    // and capture — and every iteration after that, since the sensor
    // never reports `.critical` again — so framesWritten would be > 0.
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: OneShotCriticalSensor())

    let completion = try await coordinator.run(manifest: manifest(frames: 20),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 0)
}

@Test func zeroFrameCountFinalisesAnEmptySessionWithoutCrashing() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    let completion = try await coordinator.run(manifest: manifest(frames: 0),
                                               settings: stdSettings(), isDark: false)
    #expect(completion.framesWritten == 0)

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    #expect(FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("completion.json").path))
}

@Test func finalisesSessionWhenApplyRejectsSettingsBeforeAnyFrame() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    await #expect(throws: CaptureError.self) {
        _ = try await coordinator.run(manifest: manifest(frames: 5),
                                      settings: rejectedSettings(), isDark: false)
    }

    let dir = try FileManager.default
        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)[0]
    let completionURL = dir.appendingPathComponent("completion.json")
    #expect(FileManager.default.fileExists(atPath: completionURL.path))
    // completion.json is written with .iso8601 date encoding (spec) — the
    // decoder here must match, or this is exactly the silent read-back
    // break FIX 4(a) warns about.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let completion = try decoder.decode(SessionCompletion.self,
                                        from: Data(contentsOf: completionURL))
    #expect(completion.framesWritten == 0)
}

@Test func negativeLensIndexThrowsInvalidLensIndexRatherThanTrapping() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    var negative = stdSettings()
    negative.lensIndex = -1

    do {
        _ = try await coordinator.run(manifest: manifest(frames: 5, settings: negative),
                                      settings: negative, isDark: false)
        Issue.record("expected invalidLensIndex to be thrown")
    } catch CaptureError.invalidLensIndex(let index) {
        #expect(index == -1)
    }
}

@Test func outOfRangeLensIndexThrowsInvalidLensIndexRatherThanTrapping() async throws {
    let root = tempRoot()
    let coordinator = CaptureCoordinator(
        camera: SyntheticDriver(capabilities: caps(), seed: 42),
        store: SessionStore(root: root),
        sensor: StubSensor())

    var outOfRange = stdSettings()
    outOfRange.lensIndex = 99

    do {
        _ = try await coordinator.run(manifest: manifest(frames: 5, settings: outOfRange),
                                      settings: outOfRange, isDark: false)
        Issue.record("expected invalidLensIndex to be thrown")
    } catch CaptureError.invalidLensIndex(let index) {
        #expect(index == 99)
    }
}
