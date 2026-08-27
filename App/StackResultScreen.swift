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
    /// Used to name exported files, so a file still says where it came from
    /// once it has left the app.
    var sessionName: String = "DeepSky"

    @State private var exportedFile: ExportedFile?
    @State private var exportError: String?

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
    @State private var framesDone = 0
    /// Spec §18's OFF ─── MAX control. Zero by default: an enhancement the
    /// user did not ask for is a claim about their photograph.
    @State private var enhancement = 0.0
    /// The rendered picture, produced off the main actor.
    @State private var displayImage: CGImage?
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
        .task(id: renderKey) { await refreshDisplay() }
        .sheet(item: $exportedFile) { file in
            ShareSheet(url: file.url)
        }
    }

    /// Determinate, and driven by the pipeline's own per-frame callback.
    ///
    /// It used to pass `progress: nil` and animate nothing, so a stack that
    /// was working normally was indistinguishable from one that had hung —
    /// and a debug build made that wait long enough to look like the latter.
    private var working: some View {
        VStack(spacing: DS.sm) {
            ProgressView(value: Double(framesDone), total: Double(max(frameURLs.count, 1)))
                .tint(DS.accent(nightMode))
            Text("Stacking frame \(min(framesDone + 1, frameURLs.count)) of \(frameURLs.count)…")
                .font(.system(size: 13))
                .foregroundStyle(DS.primaryText(nightMode))
            Text(framesDone >= frameURLs.count
                 ? "Measuring noise…"
                 : "Each frame is decoded, aligned, added, then discarded — memory stays flat however many there are.")
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

    /// Everything the displayed picture depends on.
    ///
    /// `.task(id:)` keys off this, which gives cancellation-based debouncing
    /// for free: dragging the slider supersedes the in-flight render rather
    /// than queueing a hundred of them.
    private struct RenderKey: Equatable {
        let stacked: Bool
        let stretch: StretchMode
        let enhancement: Double
        /// Included so the FIRST render is triggered too. Without it the key
        /// never changes when stacking finishes, and the picture never appears.
        let ready: Bool
    }

    private var renderKey: RenderKey {
        RenderKey(stacked: showingStacked, stretch: stretch,
                  enhancement: enhancement, ready: result != nil)
    }

    /// Pure and `nonisolated`, so it can run off the main actor.
    ///
    /// It has to: the stretch and the local-contrast pass together take about
    /// a tenth of a second at this resolution, and doing that inside a view
    /// body would stutter the slider it is driven by.
    nonisolated private static func render(_ result: StackResult, key: RenderKey) -> RGBImage {
        let image = key.stacked ? result.stacked : result.singleFrame
        // Each image is stretched against ITS OWN measured noise. That is the
        // entire mechanism: the stack's noise is lower, so its black point
        // sits closer to the background and faint signal is lifted further.
        // Handing both the same sigma would hide exactly what stacking bought.
        let sigma = key.stacked ? result.temporalNoiseStacked : result.temporalNoiseSingle
        let rendered = key.stretch == .auto
            ? ColourRender.display(image, measuredSigma: sigma)
            : image.map { ToneMapper.map($0) }
        // Applied last, on display-referred data: local contrast is a look
        // control and behaves predictably against the midtones the viewer
        // actually sees, not against linear sensor values.
        return MilkyWayEnhance.apply(rendered, amount: Float(key.enhancement))
    }

    private func refreshDisplay() async {
        guard let result else { return }
        let key = renderKey
        let image = await Task.detached(priority: .userInitiated) {
            Self.render(result, key: key)
        }.value
        guard !Task.isCancelled else { return }
        displayImage = RGBImageRenderer.cgImage(image)
    }

    @ViewBuilder
    private func comparison(_ result: StackResult) -> some View {
        if let cg = displayImage {
            Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.radius))
        } else {
            // Only while a re-render is in flight, so it should barely be seen.
            RoundedRectangle(cornerRadius: DS.radius)
                .fill(DS.surface)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { ProgressView().tint(DS.accent(nightMode)) }
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

        enhancementSlider

        exportSection(result)

        if stretch == .auto, let improvement = result.temporalImprovement, improvement > 1 {
            Text(String(format: "Lower noise lets the stack clip %.1f× closer to the background — that is where the faint detail comes from.",
                        improvement))
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.secondaryText(nightMode))
                .padding(.top, DS.xs)
        }
    }

    /// Spec §18. Band-limited local contrast, so it lifts structure that was
    /// photographed and leaves noise and stars alone.
    private var enhancementSlider: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack {
                Text("MILKY WAY").label(9)
                    .foregroundStyle(DS.secondaryText(nightMode))
                Spacer()
                Text(enhancement == 0 ? "OFF" : String(format: "%.0f%%", enhancement * 100))
                    .readout(13)
                    .foregroundStyle(enhancement == 0
                                     ? DS.secondaryText(nightMode) : DS.accent(nightMode))
            }
            Slider(value: $enhancement, in: 0...1)
                .tint(DS.accent(nightMode))
            Text("Amplifies structure already in the frame. It cannot add detail that was not photographed — on a blank sky this does nothing.")
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
        }
        .padding(DS.md)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
        .padding(.top, DS.sm)
    }

    /// Exports the processed image — spec §36. The RAW frames already leave
    /// via the session folder; this is the picture itself.
    @ViewBuilder
    private func exportSection(_ result: StackResult) -> some View {
        VStack(spacing: DS.sm) {
            Menu {
                ForEach(ImageExport.Format.allCases, id: \.self) { format in
                    Button {
                        export(result, as: format)
                    } label: {
                        // The summary is what makes the choice answerable
                        // without already knowing the formats.
                        Text("\(format.displayName) — \(format.summary)")
                    }
                }
            } label: {
                Label("Export image", systemImage: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.sm)
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.radius))
            }
            .foregroundStyle(DS.accent(nightMode))

            // Stated rather than hidden: the pipeline still processes at 1024px,
            // so an export is that size and not the sensor's 12MP.
            Text("Exports the image shown, at \(result.stacked.width)×\(result.stacked.height). Full-resolution processing is not built yet.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(DS.secondaryText(nightMode))

            if let exportError {
                Text(exportError)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.status(2, night: nightMode))
            }
        }
        .padding(.top, DS.sm)
    }

    private func export(_ result: StackResult, as format: ImageExport.Format) {
        exportError = nil
        let key = renderKey
        let name = sessionName
        let frames = showingStacked ? result.framesUsed : 1

        Task {
            do {
                // Encoding a 16-bit TIFF is not free; keep it off the main
                // actor so the sheet does not appear after a visible stall.
                let url = try await Task.detached(priority: .userInitiated) {
                    // Re-rendered from the same key, so the file is exactly
                    // the picture on screen rather than a near-miss.
                    let image = Self.render(result, key: key)
                    return try ImageExport.write(image, format: format,
                                                 sessionName: name, frameCount: frames,
                                                 to: URL.temporaryDirectory)
                }.value
                exportedFile = ExportedFile(url: url)
            } catch {
                exportError = "Could not export \(format.displayName): \(error)"
            }
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

    private func improvementColour(_ result: StackResult) -> Color {
        (result.temporalImprovement ?? 0) >= 1.0
            ? DS.accent(nightMode) : DS.status(1, night: nightMode)
    }

    private func stack() async {
        let urls = frameURLs

        // Off the main actor: decoding several 12MP RAWs would otherwise
        // block the UI for seconds.
        let work = Task.detached(priority: .userInitiated) { () throws -> StackResult in
            try StackPipeline.run(frameURLs: urls, maxDimension: 1024) { done, _ in
                Task { @MainActor in framesDone = done }
            }
        }

        do {
            // `.task` cancels its own body when the view goes away, but a
            // detached task is not its child and would otherwise keep burning
            // CPU after the user has navigated off the screen.
            result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch is CancellationError {
            // The user left. There is nothing to report to a screen that is
            // already gone.
        } catch {
            errorMessage = "Could not stack this session: \(error)"
        }
    }
}

/// Renders three float planes to a displayable CGImage.
///
/// sRGB rather than a linear space: `ColourRender` has already taken the data
/// to display-referred values, so tagging it linear would make the system
/// apply a second transfer and wash the result out.
enum RGBImageRenderer {
    static func cgImage(_ image: RGBImage) -> CGImage? {
        let count = image.width * image.height
        var bytes = [UInt8](repeating: 0, count: count * 3)
        for i in 0..<count {
            bytes[i * 3] = UInt8(min(max(image.red.pixels[i], 0), 1) * 255)
            bytes[i * 3 + 1] = UInt8(min(max(image.green.pixels[i], 0), 1) * 255)
            bytes[i * 3 + 2] = UInt8(min(max(image.blue.pixels[i], 0), 1) * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: image.width * 3, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
