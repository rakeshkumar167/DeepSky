import SwiftUI
import CoreGraphics
import DeepSkyProcessing

/// Stacks a session and shows the result against a single frame.
///
/// Both images are tone-mapped **identically**, so the comparison is honest
/// rather than flattering. It would be trivial to make the stack look better
/// by giving it a gentler curve; that would prove nothing.
struct StackResultScreen: View {
    let frameURLs: [URL]
    let nightMode: Bool
    /// Fraction of the session's frames flagged for movement, from the manifest.
    let motionFlaggedFraction: Double

    /// How each image is rendered for display.
    enum StretchMode: String, CaseIterable {
        /// Each image pushed as far as its own noise allows. This is what
        /// stacking actually buys you — averaging cannot add brightness, but a
        /// quieter image tolerates a far harder stretch, and that is where the
        /// faint detail appears.
        case auto = "Autostretch"
        /// Both through one identical curve. Isolates noise reduction, at the
        /// cost of the stack looking no brighter than a single frame.
        case matched = "Matched"
    }

    @State private var result: StackResult?
    @State private var showingStacked = true
    @State private var stretch: StretchMode = .auto
    @State private var progress = 0.0
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: DS.md) {
                if let result {
                    comparison(result)
                } else if let errorMessage {
                    failure(errorMessage)
                } else {
                    working
                }
            }
            .padding(DS.md)
        }
        .background(DS.background)
        .navigationTitle("Stacked result")
        .navigationBarTitleDisplayMode(.inline)
        .task { await stack() }
    }

    private var working: some View {
        VStack(spacing: DS.sm) {
            ProgressView(value: progress).tint(DS.accent(nightMode))
            Text("Stacking \(frameURLs.count) frames…")
                .font(.system(size: 13))
                .foregroundStyle(DS.secondaryText(nightMode))
            Text("Each frame is decoded, added, then discarded — memory stays flat however many there are.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.secondaryText(nightMode))
        }
        .padding(.vertical, DS.xl)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: DS.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(DS.status(2, night: nightMode))
            Text(message)
                .font(.system(size: 13)).multilineTextAlignment(.center)
                .foregroundStyle(DS.primaryText(nightMode))
        }
        .padding(.vertical, DS.xl)
    }

    @ViewBuilder
    private func comparison(_ result: StackResult) -> some View {
        let image = showingStacked ? result.stacked : result.singleFrame
        let rendered = stretch == .auto ? AutoStretch.map(image) : ToneMapper.map(image)
        if let cg = GrayImageRenderer.cgImage(rendered) {
            Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.radius))
        }

        Picker("", selection: $showingStacked) {
            Text("Single frame").tag(false)
            Text("\(result.framesUsed) stacked").tag(true)
        }
        .pickerStyle(.segmented)

        Picker("", selection: $stretch) {
            ForEach(StretchMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        Text(stretch == .auto
             ? "Each image stretched as far as its own noise allows — averaging cannot add brightness, but a cleaner image survives a harder stretch, and that is where faint detail appears."
             : "Both images through one identical curve. Isolates noise reduction, so the stack will not look brighter.")
            .font(.system(size: 11))
            .foregroundStyle(DS.secondaryText(nightMode))
            .multilineTextAlignment(.center)

        VStack(spacing: DS.xs) {
            // The temporal measurement is the honest one: spatial sigma over a
            // patch is dominated by scene structure and cannot see stacking
            // work at all.
            Text(String(format: "%.2f× less noise", result.temporalImprovement ?? 0))
                .readout(26, weight: .bold)
                .foregroundStyle(improvementColour(result))
            Text(String(format: "ideal for %d frames is %.2f×",
                        result.framesUsed, result.expectedImprovement))
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
            if result.maxDriftPixels > 0 {
                Text("aligned up to \(result.maxDriftPixels)px of drift")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.secondaryText(nightMode))
            }
        }
        .padding(.top, DS.sm)

        // A result below 1.0 is not a rendering quirk — it means the frames
        // moved, and the user should be told why rather than left to wonder.
        if let improvement = result.temporalImprovement, improvement < 1.0 {
            explanation(
                icon: "exclamationmark.triangle.fill",
                level: 1,
                title: "Stacking did not help here",
                body: motionFlaggedFraction > 0.2
                    ? "\(Int(motionFlaggedFraction * 100))% of frames were flagged for movement. With no alignment stage, frames that shift smear detail instead of averaging noise. A tripod or a braced phone is what this needs."
                    : "Noise rose rather than fell. That usually means the frames moved between exposures.")
        } else if motionFlaggedFraction > 0.2 {
            explanation(
                icon: "info.circle.fill",
                level: 1,
                title: "\(Int(motionFlaggedFraction * 100))% of frames flagged for movement",
                body: "The result improved anyway, but a steadier session would improve further.")
        }

        if result.framesFailed > 0 {
            explanation(
                icon: "doc.badge.exclamationmark",
                level: 1,
                title: "\(result.framesFailed) frames could not be decoded",
                body: "They were skipped. The rest of the session stacked normally.")
        }

        if stretch == .auto, let stacked = stretchGain(result.stacked),
           let single = stretchGain(result.singleFrame), single > 0 {
            Text(String(format: "The stack tolerates %.1f× the stretch of a single frame.",
                        stacked / single))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.secondaryText(nightMode))
                .padding(.top, DS.xs)
        }
    }

    private func explanation(icon: String, level: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: DS.sm) {
            Image(systemName: icon)
                .foregroundStyle(DS.status(level, night: nightMode))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.primaryText(nightMode))
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.secondaryText(nightMode))
            }
            Spacer()
        }
        .padding(DS.md)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
    }

    private func stretchGain(_ image: FloatImage) -> Double? {
        let gain = AutoStretch.parameters(for: image).gain
        return gain.isFinite ? Double(gain) : nil
    }

    private func improvementColour(_ result: StackResult) -> Color {
        (result.temporalImprovement ?? 0) >= 1.0
            ? DS.accent(nightMode) : DS.status(1, night: nightMode)
    }

    private func stack() async {
        let urls = frameURLs
        do {
            // Off the main actor: decoding several 12MP RAWs would otherwise
            // block the UI for seconds.
            let computed = try await Task.detached(priority: .userInitiated) {
                try StackPipeline.run(frameURLs: urls, maxDimension: 1024, progress: nil)
            }.value
            result = computed
        } catch {
            errorMessage = "Could not stack this session: \(error)"
        }
    }
}

/// Renders a single-channel float image to a displayable CGImage.
enum GrayImageRenderer {
    static func cgImage(_ image: FloatImage) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(min(max(image.pixels[i], 0), 1) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else { return nil }
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: image.width, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
