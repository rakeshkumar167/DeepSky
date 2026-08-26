import SwiftUI

/// Mock session records. Shapes match the real `SessionManifest` /
/// `SessionCompletion` types so wiring this to `SessionStore` later is a
/// substitution, not a redesign.
struct MockSession: Identifiable {
    let id = UUID()
    let name: String
    let startedAt: Date
    let lens: String
    let iso: Int
    let sensorExposure: Double
    let framesWritten: Int
    let framesPlanned: Int
    let framesFlagged: Int
    let bytes: Int
    let complete: Bool

    var effectiveExposure: Double { sensorExposure * Double(framesWritten) }

    static let samples: [MockSession] = [
        .init(name: "Milky Way — Core", startedAt: .now.addingTimeInterval(-3600),
              lens: "Wide", iso: 3200, sensorExposure: 1.0,
              framesWritten: 180, framesPlanned: 180, framesFlagged: 7,
              bytes: 4_700_000_000, complete: true),
        .init(name: "Orion", startedAt: .now.addingTimeInterval(-86_400),
              lens: "Telephoto", iso: 6400, sensorExposure: 1.0,
              framesWritten: 42, framesPlanned: 120, framesFlagged: 3,
              bytes: 1_100_000_000, complete: false),
        .init(name: "Ridge + Stars", startedAt: .now.addingTimeInterval(-172_800),
              lens: "Ultra Wide", iso: 1600, sensorExposure: 1.0,
              framesWritten: 90, framesPlanned: 90, framesFlagged: 0,
              bytes: 2_300_000_000, complete: true),
    ]
}

struct SessionsScreen: View {
    let nightMode: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(MockSession.samples) { session in
                    NavigationLink { SessionDetail(session: session, nightMode: nightMode) }
                    label: { SessionRow(session: session, nightMode: nightMode) }
                }
                .listRowBackground(DS.surface)
            }
            .scrollContentBackground(.hidden)
            .background(DS.background)
            .navigationTitle("Sessions")
        }
        .tint(DS.accent(nightMode))
    }
}

private struct SessionRow: View {
    let session: MockSession
    let nightMode: Bool

    var body: some View {
        HStack(spacing: DS.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DS.surfaceRaised)
                StarFieldThumb(seed: session.name.hashValue)
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
                        Label("Interrupted", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
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
    let session: MockSession
    let nightMode: Bool

    var body: some View {
        List {
            Section("Capture") {
                DetailRow("Lens", session.lens, nightMode)
                DetailRow("ISO", "\(session.iso)", nightMode)
                DetailRow("Sensor exposure", String(format: "%.1fs", session.sensorExposure), nightMode)
                DetailRow("Frames", "\(session.framesWritten) / \(session.framesPlanned)", nightMode)
                DetailRow("Effective exposure", "\(Int(session.effectiveExposure))s", nightMode, emphasised: true)
                DetailRow("Flagged", "\(session.framesFlagged)", nightMode)
                DetailRow("Size", ByteCountFormatStyle().format(Int64(session.bytes)), nightMode)
            }
            .listRowBackground(DS.surface)

            if !session.complete {
                Section {
                    Label {
                        Text("\(session.framesWritten) of \(session.framesPlanned) frames captured before the session was interrupted. Every frame written is intact and recoverable.")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.secondaryText(nightMode))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.status(1, night: nightMode))
                    }
                    Button("Process \(session.framesWritten) frames") {}
                    Button("Keep session") {}
                    Button("Discard", role: .destructive) {}
                }
                .listRowBackground(DS.surface)
            }

            Section("Frames") {
                Text("Preview only — no capture pipeline wired.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.secondaryText(nightMode))
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

/// Tiny deterministic star field used as a session thumbnail.
struct StarFieldThumb: View {
    let seed: Int
    var body: some View {
        Canvas { ctx, size in
            var rng = SystemRandomNumberGeneratorSeeded(seed: UInt64(truncatingIfNeeded: seed))
            for _ in 0..<26 {
                let x = Double.random(in: 0...size.width, using: &rng)
                let y = Double.random(in: 0...size.height, using: &rng)
                let r = Double.random(in: 0.3...1.1, using: &rng)
                let a = Double.random(in: 0.3...1.0, using: &rng)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(a)))
            }
        }
        .background(Color(red: 0.02, green: 0.03, blue: 0.07))
    }
}

struct SystemRandomNumberGeneratorSeeded: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
