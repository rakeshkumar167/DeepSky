import SwiftUI
import DeepSkyCore
import DeepSkyAVCapture

/// The first thing DeepSky ever put on a phone: read what this device's
/// cameras can actually do, show it, and let it off the device as JSON.
///
/// The output is a fixture. Committing one per device is what lets the
/// shutter ladder and stability banding be tested against real hardware
/// limits instead of assumptions.
struct ProbeView: View {
    @State private var state: ProbeState = .idle

    enum ProbeState {
        case idle
        case running
        case failed(String)
        case done(summary: [LensSummary], fileURL: URL, json: String)
    }

    struct LensSummary: Identifiable {
        let id = UUID()
        let name: String
        let focalLength: Int?
        let formatCount: Int
        let maxExposureSeconds: Double
        let minExposureSeconds: Double
        let maxISO: Float
        let rawFormats: [String]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle:      idleView
                case .running:   ProgressView("Probing cameras…")
                case .failed(let message): failureView(message)
                case .done(let summary, let url, let json): resultView(summary, url, json)
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
            Text("Reads the real exposure, ISO and RAW limits of this iPhone's cameras.")
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

    private func resultView(_ summary: [LensSummary], _ url: URL, _ json: String) -> some View {
        List {
            Section {
                ForEach(summary) { lens in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lens.name).font(.headline)
                            Spacer()
                            if let f = lens.focalLength {
                                Text("\(f)mm").foregroundStyle(.secondary)
                            }
                        }
                        // The number this whole app is designed around.
                        Text("Max sensor exposure: \(lens.maxExposureSeconds, format: .number.precision(.fractionLength(3)))s")
                            .font(.callout).bold()
                        Text("Min exposure: 1/\(Int((1 / max(lens.minExposureSeconds, 1e-9)).rounded()))   •   Max ISO: \(Int(lens.maxISO))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(lens.formatCount) formats   •   RAW: \(lens.rawFormats.isEmpty ? "none" : lens.rawFormats.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Back cameras")
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
                Text("Also visible in Files under On My iPhone → DeepSky. Commit one per device.")
            }

            Section("Raw JSON") {
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
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

            let summary = capabilities.lenses.map { lens in
                LensSummary(
                    name: lens.localizedName,
                    focalLength: lens.focalLengthEquivalent,
                    formatCount: lens.formats.count,
                    maxExposureSeconds: lens.formats.map(\.maxExposureSeconds).max() ?? 0,
                    minExposureSeconds: lens.formats.map(\.minExposureSeconds).min() ?? 0,
                    maxISO: lens.formats.map(\.maxISO).max() ?? 0,
                    rawFormats: Array(Set(lens.formats.flatMap(\.rawPixelFormats))).sorted())
            }

            state = .done(
                summary: summary,
                fileURL: url,
                json: String(decoding: data, as: UTF8.self))
        } catch {
            state = .failed("Probe failed: \(error)")
        }
    }
}
