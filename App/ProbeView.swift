import SwiftUI
import DeepSkyCore
import DeepSkyAVCapture

/// The first thing DeepSky ever put on a phone: read what this device's
/// cameras can actually do, derive the honest shutter ladder from it, and
/// let the raw numbers off the device as JSON.
///
/// The JSON is a fixture. Committing one per device is what lets
/// `ShutterLadder` and `StabilityEstimator` be tested against real hardware
/// limits instead of assumptions.
struct ProbeView: View {
    @State private var state: ProbeState = .idle

    enum ProbeState {
        case idle
        case running
        case failed(String)
        case done(lenses: [LensSummary], fileURL: URL, json: String)
    }

    struct LensSummary: Identifiable {
        let id = UUID()
        let name: String
        let focalLength: Int?
        let formatCount: Int
        /// The format an astro capture would actually select, and the ladder derived from it.
        let astroFormat: FormatCapability
        let ladder: [ShutterSpeed]
        let rawFormats: [String]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle:      idleView
                case .running:   ProgressView("Probing cameras…")
                case .failed(let message): failureView(message)
                case .done(let lenses, let url, let json): resultView(lenses, url, json)
                }
            }
            .padding()
            .navigationTitle("Capability Probe")
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Reads the real exposure, ISO and RAW limits of this iPhone's cameras, then derives the shutter ladder from them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Run Probe") { Task { await runProbe() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("Try Again") { Task { await runProbe() } }
        }
    }

    private func resultView(_ lenses: [LensSummary], _ url: URL, _ json: String) -> some View {
        List {
            ForEach(lenses) { lens in
                Section {
                    // The number this whole app is designed around.
                    LabeledContent("Max sensor exposure") {
                        Text(ShutterSpeed(seconds: lens.astroFormat.maxExposureSeconds).displayLabel)
                            .bold().monospacedDigit()
                    }
                    LabeledContent("Shortest exposure") {
                        Text(ShutterSpeed(seconds: lens.astroFormat.minExposureSeconds).displayLabel)
                            .monospacedDigit()
                    }
                    LabeledContent("ISO range") {
                        Text("\(Int(lens.astroFormat.minISO))–\(Int(lens.astroFormat.maxISO))")
                            .monospacedDigit()
                    }
                    LabeledContent("Field of view") {
                        Text("\(lens.astroFormat.horizontalFieldOfViewDegrees, format: .number.precision(.fractionLength(1)))°")
                            .monospacedDigit()
                    }
                    LabeledContent("Sensor") {
                        Text("\(lens.astroFormat.width)×\(lens.astroFormat.height)")
                            .monospacedDigit()
                    }
                    LabeledContent("RAW") {
                        Text(lens.rawFormats.isEmpty ? "none" : lens.rawFormats.joined(separator: " "))
                            .monospacedDigit()
                    }

                    DisclosureGroup("Derived shutter ladder (\(lens.ladder.count))") {
                        Text(lens.ladder.map(\.displayLabel).joined(separator: "   "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    effectiveExposureNote(for: lens)
                } header: {
                    HStack {
                        Text(lens.name)
                        Spacer()
                        if let f = lens.focalLength { Text("≈\(f)mm").foregroundStyle(.secondary) }
                    }
                } footer: {
                    Text("Ladder derived from this lens's astro format (\(lens.formatCount) formats available). Entries the hardware cannot deliver never appear.")
                }
            }

            Section {
                ShareLink(item: url) {
                    Label("Export capabilities.json", systemImage: "square.and.arrow.up")
                }
                Text(url.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Fixture")
            } footer: {
                Text("Also in Files under On My iPhone → DeepSky. Commit one per device.")
            }

            Section("Raw JSON") {
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    /// Spells out the §27 distinction the product depends on: the sensor's real
    /// exposure ceiling versus what stacking is equivalent to. If the ceiling is
    /// ~1s, a "60 second exposure" is 60 stacked frames, and saying otherwise
    /// would be a lie about physics.
    private func effectiveExposureNote(for lens: LensSummary) -> some View {
        let longest = lens.ladder.last ?? ShutterSpeed(seconds: lens.astroFormat.maxExposureSeconds)
        let plan = CapturePlan.solve(
            totalCaptureSeconds: 60, sensorExposure: longest, intervalSeconds: 0)
        return VStack(alignment: .leading, spacing: 4) {
            Text("A 60-second exposure on this lens")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(plan.frameCount) × \(longest.displayLabel) stacked")
                .font(.callout).bold()
            Text("Effective \(plan.effectiveExposureSeconds, format: .number.precision(.fractionLength(0)))s · sensor never exposes longer than \(longest.displayLabel)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Picks the format an astro capture would actually use: the longest
    /// possible sensor exposure first, then the largest sensor area to break
    /// ties. Exposure ceiling dominates because it sets how few frames a given
    /// effective exposure needs, and every extra frame is more alignment error.
    private func astroFormat(from formats: [FormatCapability]) -> FormatCapability? {
        formats.max { a, b in
            if a.maxExposureSeconds != b.maxExposureSeconds {
                return a.maxExposureSeconds < b.maxExposureSeconds
            }
            return (a.width * a.height) < (b.width * b.height)
        }
    }

    private func runProbe() async {
        state = .running

        guard await CapabilityProbe.requestAccess() else {
            state = .failed("Camera access denied. Enable it in Settings → DeepSky.")
            return
        }

        do {
            let capabilities = try CapabilityProbe.run()

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Matches SessionStore, so probe fixtures and session.json agree.
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(capabilities)

            let url = URL.documentsDirectory
                .appendingPathComponent("capabilities-\(capabilities.deviceModel).json")
            try data.write(to: url, options: .atomic)

            let lenses: [LensSummary] = capabilities.lenses.compactMap { lens in
                guard let format = astroFormat(from: lens.formats) else { return nil }
                return LensSummary(
                    name: lens.localizedName,
                    focalLength: lens.focalLengthEquivalent,
                    formatCount: lens.formats.count,
                    astroFormat: format,
                    ladder: ShutterLadder.ladder(for: format),
                    rawFormats: Array(Set(lens.formats.flatMap(\.rawPixelFormats))).sorted())
            }

            state = .done(
                lenses: lenses,
                fileURL: url,
                json: String(decoding: data, as: UTF8.self))
        } catch {
            state = .failed("Probe failed: \(error)")
        }
    }
}
