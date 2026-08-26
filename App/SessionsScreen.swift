import SwiftUI
import DeepSkyCore
import DeepSkySession

/// A session as read back off disk.
///
/// Built from `session.json` plus the append-only `frames.jsonl`, so a session
/// interrupted mid-capture reads correctly rather than not at all — that
/// recovery path is core to the design, not an error case.
struct SessionSummary: Identifiable {
    let id: String
    let url: URL
    let name: String
    let startedAt: Date
    let lensName: String
    let iso: Int
    let sensorExposure: Double
    let framesWritten: Int
    let framesPlanned: Int
    let framesFlagged: Int
    let bytes: Int64
    let complete: Bool

    var effectiveExposure: Double { sensorExposure * Double(framesWritten) }

    /// Fraction of frames the capture flagged for movement. The stacker has no
    /// alignment stage, so this decides whether stacking can help at all.
    var motionFlaggedFraction: Double {
        framesWritten > 0 ? Double(framesFlagged) / Double(framesWritten) : 0
    }

    /// The DNGs on disk, in capture order.
    var frameURLs: [URL] {
        let dir = url.appendingPathComponent("frames")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadAll() -> [SessionSummary] {
        let root = URL.documentsDirectory.appendingPathComponent("Sessions")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // must match SessionStore

        return entries.compactMap { dir -> SessionSummary? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let manifest = try? decoder.decode(SessionManifest.self, from: data)
            else { return nil }

            let frames = (try? SessionStore.readFrames(at: dir)) ?? []
            let complete = fm.fileExists(atPath: dir.appendingPathComponent("completion.json").path)

            return SessionSummary(
                id: manifest.id,
                url: dir,
                name: manifest.name,
                startedAt: manifest.startedAt,
                lensName: manifest.capabilities.lenses.indices.contains(manifest.settings.lensIndex)
                    ? manifest.capabilities.lenses[manifest.settings.lensIndex].localizedName
                    : "Unknown lens",
                iso: Int(manifest.settings.iso),
                sensorExposure: manifest.settings.exposure.seconds,
                framesWritten: frames.count,
                framesPlanned: manifest.plan.frameCount,
                framesFlagged: frames.filter { !$0.flags.isEmpty }.count,
                bytes: frames.reduce(0) { $0 + Int64($1.bytes) },
                complete: complete)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}

struct SessionsScreen: View {
    let nightMode: Bool
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty { emptyState } else { list }
            }
            .background(DS.background)
            .navigationTitle("Sessions")
        }
        .tint(DS.accent(nightMode))
        .onAppear { sessions = SessionSummary.loadAll() }
        .refreshable { sessions = SessionSummary.loadAll() }
    }

    private var emptyState: some View {
        VStack(spacing: DS.md) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 48)).foregroundStyle(DS.secondaryText(nightMode))
            Text("No sessions yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.primaryText(nightMode))
            Text("Captured sessions appear here, and in Files under On My iPhone → DeepSky.")
                .font(.system(size: 13)).multilineTextAlignment(.center)
                .foregroundStyle(DS.secondaryText(nightMode))
                .padding(.horizontal, DS.xl)
        }
    }

    private var list: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink { SessionDetail(session: session, nightMode: nightMode) }
                label: { SessionRow(session: session, nightMode: nightMode) }
            }
            .listRowBackground(DS.surface)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let nightMode: Bool

    var body: some View {
        HStack(spacing: DS.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(DS.surfaceRaised)
                StarFieldThumb(seed: session.id.hashValue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.primaryText(nightMode))
                Text(session.startedAt, format: .dateTime.hour().minute().day().month())
                    .font(.system(size: 12))
                    .foregroundStyle(DS.secondaryText(nightMode))
                HStack(spacing: DS.sm) {
                    // Effective exposure, never presented as a sensor exposure.
                    Text("\(session.framesWritten)×\(session.sensorExposure, format: .number.precision(.fractionLength(1)))s")
                        .readout(12, weight: .medium)
                    Text("→ \(Int(session.effectiveExposure))s")
                        .readout(12, weight: .medium)
                    if !session.complete {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.status(1, night: nightMode))
                            .accessibilityLabel("Interrupted session")
                    }
                }
                .foregroundStyle(DS.secondaryText(nightMode))
            }
            Spacer()
        }
        .padding(.vertical, DS.xs)
    }
}

private struct SessionDetail: View {
    let session: SessionSummary
    let nightMode: Bool

    var body: some View {
        List {
            Section("Capture") {
                DetailRow("Lens", session.lensName, nightMode)
                DetailRow("ISO", "\(session.iso)", nightMode)
                DetailRow("Sensor exposure", String(format: "%.1fs", session.sensorExposure), nightMode)
                DetailRow("Frames", "\(session.framesWritten) / \(session.framesPlanned)", nightMode)
                DetailRow("Effective exposure", "\(Int(session.effectiveExposure))s", nightMode, emphasised: true)
                DetailRow("Flagged", "\(session.framesFlagged)", nightMode)
                DetailRow("Size", ByteCountFormatStyle().format(session.bytes), nightMode)
                if session.framesWritten > 0 {
                    DetailRow("Per frame",
                              ByteCountFormatStyle().format(session.bytes / Int64(session.framesWritten)),
                              nightMode)
                }
            }
            .listRowBackground(DS.surface)

            if !session.complete {
                Section {
                    Label {
                        Text("\(session.framesWritten) of \(session.framesPlanned) frames captured before the session ended. Every frame written is intact and recoverable.")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.secondaryText(nightMode))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.status(1, night: nightMode))
                    }
                }
                .listRowBackground(DS.surface)
            }

            Section {
                if session.framesWritten >= 2 {
                    NavigationLink {
                        StackResultScreen(frameURLs: session.frameURLs,
                                          nightMode: nightMode,
                                          motionFlaggedFraction: session.motionFlaggedFraction)
                    } label: {
                        Label("Stack \(session.framesWritten) frames", systemImage: "square.3.layers.3d")
                    }
                } else {
                    Text("At least two frames are needed to stack.")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.secondaryText(nightMode))
                }
            } header: {
                Text("Process")
            }
            .listRowBackground(DS.surface)

            Section {
                ShareLink(item: session.url) {
                    Label("Export session folder", systemImage: "square.and.arrow.up")
                }
                Text(session.url.lastPathComponent)
                    .font(.caption).foregroundStyle(DS.secondaryText(nightMode))
                    .textSelection(.enabled)
            } header: {
                Text("Files")
            } footer: {
                Text("Also in Files under On My iPhone → DeepSky → Sessions.")
            }
            .listRowBackground(DS.surface)
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailRow: View {
    let key: String, value: String, night: Bool, emphasised: Bool
    init(_ k: String, _ v: String, _ n: Bool, emphasised: Bool = false) {
        key = k; value = v; night = n; self.emphasised = emphasised
    }
    var body: some View {
        HStack {
            Text(key).font(.system(size: 15)).foregroundStyle(DS.secondaryText(night))
            Spacer()
            Text(value)
                .readout(15, weight: emphasised ? .bold : .medium)
                .foregroundStyle(emphasised ? DS.accent(night) : DS.primaryText(night))
        }
    }
}
