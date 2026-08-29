import SwiftUI
import DeepSkyCore

/// The ASTRO capture screen, wired to real hardware.
///
/// Settings are derived by `AstroPreset` from what this device reported, not
/// chosen here. The user controls focus and how many frames to integrate;
/// everything else is decided by the preset, which is the whole point of the
/// MVP's control scope.
///
/// The live view is the real camera feed, sharing the capture session so it
/// shows the frame at the settings the app will actually shoot with. The
/// procedural star field remains only as the placeholder shown while the
/// hardware is being probed, and the badge says which of the two is on screen.
struct CameraScreen: View {
    @Binding var nightMode: Bool

    @State private var model = CaptureModel()
    @State private var showLoupe = false
    @AppStorage("hasSeenShutterSoundTip") private var hasSeenShutterSoundTip = false

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            // The real feed as soon as the session exists; the procedural
            // field only covers the probe, so the screen is never empty.
            if let session = model.previewSession {
                CameraPreview(session: session)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                LiveViewPlaceholder(nightMode: nightMode).ignoresSafeArea()
            }

            if showLoupe { FocusLoupe(nightMode: nightMode, sharpness: sharpness) }

            VStack(spacing: 0) {
                statusBar
                Spacer()
                phaseContent
                controlStrip
                if !hasSeenShutterSoundTip, case .ready = model.phase {
                    shutterSoundTip
                }
                captureRow
            }
            .padding(.horizontal, DS.md)
            .padding(.bottom, DS.sm)
        }
        .task { await model.prepare() }
    }

    // MARK: - Top status

    private var statusBar: some View {
        VStack(spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Text("ASTRO").label(13).foregroundStyle(DS.accent(nightMode))
                Text(model.lensName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.secondaryText(nightMode))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.2)) { nightMode.toggle() } } label: {
                    Image(systemName: nightMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(nightMode
                    ? "Night mode on. Switch to standard colours."
                    : "Standard colours. Switch to night mode.")
                .foregroundStyle(DS.primaryText(nightMode))
            }

            HStack(spacing: 0) {
                readoutCell("ISO", model.isoLabel)
                readoutCell("SHUTTER", model.shutterLabel)
                readoutCell("FOCUS", model.lensPosition >= 0.999
                            ? "∞" : String(format: "%.2f", model.lensPosition))
                readoutCell("WB", "3900K")
            }

            HStack(spacing: DS.md) {
                // Says which of the two it is, so nobody judges focus by a
                // simulation — or dismisses the real feed as one.
                Label(model.previewSession == nil ? "Simulated view" : "Live view",
                      systemImage: model.previewSession == nil ? "eye.slash" : "eye")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.previewSession == nil
                                     ? DS.secondaryText(nightMode) : DS.accent(nightMode))
                Spacer()
                HistogramStrip(nightMode: nightMode)
            }
        }
        .padding(DS.md)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: DS.radius))
        .padding(.top, DS.sm)
    }

    private func readoutCell(_ key: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(key).label(9).foregroundStyle(DS.secondaryText(nightMode))
            Text(value).readout(17).foregroundStyle(DS.primaryText(nightMode))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Phase-dependent middle section

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .idle, .preparing:
            VStack(spacing: DS.sm) {
                ProgressView().tint(DS.accent(nightMode))
                Text("Reading camera limits…")
                    .font(.system(size: 12)).foregroundStyle(DS.secondaryText(nightMode))
            }
            .padding(.vertical, DS.lg)

        case .ready:
            planStrip

        case .countdown(let remaining):
            VStack(spacing: DS.xs) {
                Text("\(remaining)").readout(28, weight: .bold)
                    .foregroundStyle(DS.accent(nightMode))
                Text("Hold steady…")
                    .font(.system(size: 11)).foregroundStyle(DS.secondaryText(nightMode))
            }
            .padding(.vertical, DS.md)

        case .capturing(let done, let total):
            captureProgress(done: done, total: total)

        case .finished(let written, let flagged, let interrupted):
            resultStrip(written: written, flagged: flagged, interrupted: interrupted)

        case .failed(let message):
            VStack(spacing: DS.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(DS.status(2, night: nightMode))
                Text(message)
                    .font(.system(size: 13)).multilineTextAlignment(.center)
                    .foregroundStyle(DS.primaryText(nightMode))
                Button("Try again") { Task { model.reset(); await model.prepare() } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.accent(nightMode))
            }
            .padding(.vertical, DS.md)
        }
    }

    /// The §27 honesty surface: sensor exposure and effective exposure are
    /// separate numbers and the sensor's real ceiling is stated inline.
    private var planStrip: some View {
        VStack(spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text("\(model.requestedFrames)").readout(28, weight: .bold)
                Text("×").readout(18).foregroundStyle(DS.secondaryText(nightMode))
                Text(model.shutterLabel).readout(28, weight: .bold)
                Text("→").readout(18).foregroundStyle(DS.secondaryText(nightMode))
                Text(durationLabel(model.effectiveExposureSeconds)).readout(28, weight: .bold)
                    .foregroundStyle(DS.accent(nightMode))
            }
            .foregroundStyle(DS.primaryText(nightMode))

            Text("effective exposure · sensor never exposes longer than \(model.shutterLabel)")
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan: \(model.requestedFrames) frames of \(model.shutterLabel) each, \(durationLabel(model.effectiveExposureSeconds)) effective exposure")
    }

    private func captureProgress(done: Int, total: Int) -> some View {
        VStack(spacing: DS.sm) {
            HStack {
                Text("\(done) / \(total)").readout(24, weight: .bold)
                    .foregroundStyle(DS.primaryText(nightMode))
                Spacer()
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(DS.accent(nightMode))
            Text("Frames are written as they are captured. Stopping early keeps everything already on disk.")
                .font(.system(size: 11)).foregroundStyle(DS.secondaryText(nightMode))
        }
        .padding(.vertical, DS.md)
    }

    private func resultStrip(written: Int, flagged: Int, interrupted: Bool) -> some View {
        VStack(spacing: DS.xs) {
            Text("\(written) frames captured").readout(22, weight: .bold)
                .foregroundStyle(DS.primaryText(nightMode))
            if interrupted {
                Label("The camera stopped early — the screen locked or DeepSky left the foreground. These frames are fine.",
                      systemImage: "moon.zzz.fill")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(DS.status(1, night: nightMode))
            }
            if flagged > 0 {
                Label("\(flagged) flagged for movement — kept, not discarded",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.status(1, night: nightMode))
            }
            Text("Find them in Sessions, or export from Files.")
                .font(.system(size: 11)).foregroundStyle(DS.secondaryText(nightMode))
            Button("New session") { model.reset() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.accent(nightMode))
                .padding(.top, DS.xs)
        }
        .padding(.vertical, DS.md)
    }

    // MARK: - Controls

    private var controlStrip: some View {
        VStack(spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                pill(showLoupe ? "Loupe on" : "Loupe", active: showLoupe,
                     icon: "plus.magnifyingglass") {
                    withAnimation(.easeOut(duration: 0.2)) { showLoupe.toggle() }
                }
                Spacer()
                Text("max \(model.maxFrames) frames")
                    .font(.system(size: 10)).foregroundStyle(DS.secondaryText(nightMode))
            }

            slider("Focus", value: $model.lensPosition, range: 0...1)

            slider("Frames", value: Binding(
                get: { Double(model.requestedFrames) },
                set: { model.requestedFrames = Int($0.rounded()) }),
                   range: 1...Double(max(model.maxFrames, 1)))
        }
        .padding(DS.md)
        .background(DS.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: DS.radius))
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.5 : 1)
    }

    private func slider(_ key: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        HStack(spacing: DS.md) {
            Text(key).label(10)
                .foregroundStyle(DS.secondaryText(nightMode))
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range).tint(DS.accent(nightMode))
        }
        .frame(height: 40)
        .accessibilityLabel(key)
    }

    private func pill(_ title: String, active: Bool, icon: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.xs) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, DS.md)
            .frame(height: 44)
            .background(active ? DS.accent(nightMode).opacity(0.22) : DS.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? DS.accent(nightMode) : .clear, lineWidth: 1))
            .foregroundStyle(active ? DS.accent(nightMode) : DS.secondaryText(nightMode))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capture

    /// iOS plays the system shutter sound on every `AVCapturePhotoOutput`
    /// capture and gives apps no API to suppress it — enforced at the OS
    /// level so apps can't shoot silently. The mute switch is the only real
    /// control the user has over it (outside regions where iOS ignores the
    /// switch for the camera).
    private var shutterSoundTip: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.secondaryText(nightMode))
            Text("iOS plays a shutter sound per frame during RAW capture — flip the mute switch to silence it.")
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
            Spacer(minLength: 0)
            Button {
                hasSeenShutterSoundTip = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.secondaryText(nightMode))
            }
            .accessibilityLabel("Dismiss shutter sound tip")
        }
        .padding(.horizontal, DS.md)
        .padding(.vertical, DS.sm)
        .background(DS.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.radius))
    }

    private var captureRow: some View {
        HStack {
            Spacer()
            Button {
                Task { await model.startCapture(named: "Astro") }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(DS.primaryText(nightMode).opacity(0.5), lineWidth: 3)
                        .frame(width: DS.captureButton, height: DS.captureButton)
                    Circle()
                        .fill(canCapture ? DS.accent(nightMode) : DS.surfaceRaised)
                        .frame(width: DS.captureButton - 18, height: DS.captureButton - 18)
                    if case .capturing = model.phase {
                        ProgressView().tint(DS.background)
                    } else if case .countdown(let remaining) = model.phase {
                        Text("\(remaining)")
                            .readout(28, weight: .bold)
                            .foregroundStyle(DS.background)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canCapture)
            .accessibilityLabel("Start capture")
            Spacer()
        }
        .padding(.top, DS.sm)
    }

    private var canCapture: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    // MARK: - Formatting

    /// Placeholder until the preview path lands and this reads live HFD.
    private var sharpness: Double { 0.62 + model.lensPosition * 0.36 }

    private func durationLabel(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded()))s" : "\(Int(s) / 60)m \(Int(s) % 60)s"
    }
}
