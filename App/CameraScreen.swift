import SwiftUI

/// The ASTRO capture screen.
///
/// PREVIEW ONLY — no camera is wired. The live view is a procedural star field
/// so the layout can be judged against something representative rather than a
/// grey rectangle, and the capture button runs a simulated session.
///
/// The layout is built around one rule from the spec: sensor exposure and
/// effective exposure are different numbers and must never be conflated. The
/// hardware caps a single exposure at 1.0s (confirmed on both test devices), so
/// the plan strip always reads "N × 1.0s → Ns", never "Ns exposure".
struct CameraScreen: View {
    @Binding var nightMode: Bool

    @State private var expert = false
    @State private var iso = 3200
    @State private var exposureIndex = 16       // index into the derived ladder
    @State private var frames = 60
    @State private var showLoupe = false
    @State private var capturing = false
    @State private var framesDone = 0
    @State private var focusPosition = 1.0

    /// Mirrors what `ShutterLadder` derives from real hardware: canonical stops
    /// filtered to what the sensor can actually deliver, ending at 1.0s.
    private let ladder: [Double] = [
        1/8000, 1/4000, 1/2000, 1/1000, 1/500, 1/250, 1/125,
        1/60, 1/30, 1/15, 1/8, 1/4, 1/2, 1,
    ]
    private var sensorExposure: Double { ladder[min(exposureIndex, ladder.count - 1)] }
    private var effectiveExposure: Double { sensorExposure * Double(frames) }
    private var totalCapture: Double { (sensorExposure + 0.05) * Double(frames) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.background.ignoresSafeArea()
                LiveViewPlaceholder(nightMode: nightMode)
                    .ignoresSafeArea()

                if showLoupe { FocusLoupe(nightMode: nightMode, sharpness: sharpness) }

                VStack(spacing: 0) {
                    statusBar
                    Spacer()
                    if capturing { captureProgress } else { planStrip }
                    controlStrip
                    captureRow
                }
                .padding(.horizontal, DS.md)
                .padding(.bottom, DS.sm)
            }
        }
    }

    // MARK: - Top status

    private var statusBar: some View {
        VStack(spacing: DS.sm) {
            HStack {
                Text("ASTRO").label(13).foregroundStyle(DS.accent(nightMode))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.2)) { nightMode.toggle() } } label: {
                    Image(systemName: nightMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(nightMode ? "Night mode on. Switch to standard colours." : "Standard colours. Switch to night mode.")
                .foregroundStyle(DS.primaryText(nightMode))
            }

            HStack(spacing: 0) {
                readoutCell("ISO", "\(iso)")
                readoutCell("SHUTTER", shutterLabel(sensorExposure))
                readoutCell("FOCUS", focusPosition >= 0.999 ? "∞" : String(format: "%.2f", focusPosition))
                readoutCell("WB", "3900K")
            }

            HStack(spacing: DS.md) {
                statusChip("Stability", "Excellent", icon: "checkmark.circle.fill", level: 0)
                statusChip("Thermal", "Nominal", icon: "thermometer.low", level: 0)
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

    /// Status is never carried by colour alone — icon and text always present.
    private func statusChip(_ key: String, _ value: String, icon: String, level: Int) -> some View {
        HStack(spacing: DS.xs) {
            Image(systemName: icon).font(.system(size: 11))
            Text(value).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(DS.status(level, night: nightMode))
        .accessibilityLabel("\(key): \(value)")
    }

    // MARK: - Plan strip — the §27 honesty surface

    private var planStrip: some View {
        VStack(spacing: DS.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                Text("\(frames)").readout(28, weight: .bold)
                Text("×").readout(18).foregroundStyle(DS.secondaryText(nightMode))
                Text(shutterLabel(sensorExposure)).readout(28, weight: .bold)
                Text("→").readout(18).foregroundStyle(DS.secondaryText(nightMode))
                Text(durationLabel(effectiveExposure)).readout(28, weight: .bold)
                    .foregroundStyle(DS.accent(nightMode))
            }
            .foregroundStyle(DS.primaryText(nightMode))

            Text("effective exposure · sensor never exposes longer than \(shutterLabel(sensorExposure)) · \(durationLabel(totalCapture)) on the clock")
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan: \(frames) frames of \(shutterLabel(sensorExposure)) each, \(durationLabel(effectiveExposure)) effective exposure")
    }

    private var captureProgress: some View {
        VStack(spacing: DS.sm) {
            HStack {
                Text("\(framesDone) / \(frames)").readout(24, weight: .bold)
                    .foregroundStyle(DS.primaryText(nightMode))
                Spacer()
                Text(durationLabel(Double(frames - framesDone) * (sensorExposure + 0.05)) + " left")
                    .readout(13).foregroundStyle(DS.secondaryText(nightMode))
            }
            ProgressView(value: Double(framesDone), total: Double(frames))
                .tint(DS.accent(nightMode))
            Text("Frames are written as they are captured. Stopping early keeps everything already on disk.")
                .font(.system(size: 11))
                .foregroundStyle(DS.secondaryText(nightMode))
        }
        .padding(.vertical, DS.md)
    }

    // MARK: - Controls

    private var controlStrip: some View {
        VStack(spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                pill("Simple", active: !expert) { withAnimation(.easeOut(duration: 0.2)) { expert = false } }
                pill("Expert", active: expert) { withAnimation(.easeOut(duration: 0.2)) { expert = true } }
                Spacer()
                pill(showLoupe ? "Loupe on" : "Loupe", active: showLoupe, icon: "plus.magnifyingglass") {
                    withAnimation(.easeOut(duration: 0.2)) { showLoupe.toggle() }
                }
            }

            slider("ISO", value: Binding(
                get: { Double(iso) },
                set: { iso = Int(($0 / 100).rounded()) * 100 }), range: 100...12000)

            slider("Shutter", value: Binding(
                get: { Double(exposureIndex) },
                set: { exposureIndex = Int($0.rounded()) }), range: 0...Double(ladder.count - 1))

            if expert {
                slider("Frames", value: Binding(
                    get: { Double(frames) },
                    set: { frames = Int($0.rounded()) }), range: 1...300)
                slider("Focus", value: $focusPosition, range: 0...1)
                HStack(spacing: DS.sm) {
                    pill("12 MP", active: true) {}
                    pill("48 MP", active: false) {}
                    pill("Dark frames", active: false, icon: "circle.slash") {}
                    Spacer()
                }
            }
        }
        .padding(DS.md)
        .background(DS.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: DS.radius))
    }

    private func slider(_ key: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: DS.md) {
            Text(key).label(10)
                .foregroundStyle(DS.secondaryText(nightMode))
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
                .tint(DS.accent(nightMode))
        }
        .frame(height: 40)
        .accessibilityLabel(key)
    }

    private func pill(_ title: String, active: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.xs) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, DS.md)
            .frame(height: 44)
            .background(active ? DS.accent(nightMode).opacity(0.22) : DS.surfaceRaised,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(active ? DS.accent(nightMode) : .clear, lineWidth: 1))
            .foregroundStyle(active ? DS.accent(nightMode) : DS.secondaryText(nightMode))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capture

    private var captureRow: some View {
        HStack {
            Spacer()
            Button { toggleCapture() } label: {
                ZStack {
                    Circle()
                        .strokeBorder(DS.primaryText(nightMode).opacity(0.5), lineWidth: 3)
                        .frame(width: DS.captureButton, height: DS.captureButton)
                    if capturing {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DS.bad)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(DS.accent(nightMode))
                            .frame(width: DS.captureButton - 18, height: DS.captureButton - 18)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(capturing ? "Stop capture" : "Start capture")
            .sensoryFeedback(.impact(weight: .medium), trigger: capturing)
            Spacer()
        }
        .padding(.top, DS.sm)
    }

    private func toggleCapture() {
        if capturing {
            capturing = false
        } else {
            capturing = true
            framesDone = 0
            advance()
        }
    }

    /// Simulated progress so the in-capture layout can be judged.
    private func advance() {
        guard capturing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard capturing else { return }
            if framesDone < frames {
                framesDone += 1
                advance()
            } else {
                capturing = false
            }
        }
    }

    // MARK: - Formatting

    private var sharpness: Double { 0.62 + focusPosition * 0.36 }

    private func shutterLabel(_ s: Double) -> String {
        s >= 1 ? String(format: "%.1fs", s) : "1/\(Int((1 / s).rounded()))"
    }

    private func durationLabel(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded()))s"
               : "\(Int(s) / 60)m \(Int(s) % 60)s"
    }
}

// MARK: - Live view placeholder

/// Procedural star field standing in for the camera feed, so the layout can be
/// judged against representative content. Deterministic, and deliberately not
/// photorealistic — it should never be mistaken for a real preview.
struct LiveViewPlaceholder: View {
    let nightMode: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.08),
                                    Color(red: 0.05, green: 0.06, blue: 0.13),
                                    Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var rng = SystemRandomNumberGeneratorSeeded(seed: 20260826)
                // Milky Way band: a soft diagonal brightening.
                for _ in 0..<220 {
                    let t = Double.random(in: 0...1, using: &rng)
                    let x = t * size.width
                    let y = size.height * (0.30 + 0.22 * t) + Double.random(in: -70...70, using: &rng)
                    let r = Double.random(in: 0.3...1.4, using: &rng)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(Double.random(in: 0.15...0.55, using: &rng))))
                }
                for _ in 0..<300 {
                    let x = Double.random(in: 0...size.width, using: &rng)
                    let y = Double.random(in: 0...size.height, using: &rng)
                    let r = Double.random(in: 0.2...1.7, using: &rng)
                    let a = Double.random(in: 0.2...0.95, using: &rng)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(a)))
                }
                // Horizon silhouette.
                var ridge = Path()
                ridge.move(to: CGPoint(x: 0, y: size.height))
                ridge.addLine(to: CGPoint(x: 0, y: size.height * 0.82))
                var x = 0.0
                while x < size.width {
                    x += Double.random(in: 30...90, using: &rng)
                    ridge.addLine(to: CGPoint(x: x, y: size.height * Double.random(in: 0.76...0.88, using: &rng)))
                }
                ridge.addLine(to: CGPoint(x: size.width, y: size.height))
                ridge.closeSubpath()
                ctx.fill(ridge, with: .color(.black))
            }
            if nightMode {
                // Night mode filters the whole view, preview included.
                Color(red: 0.85, green: 0.10, blue: 0.06)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Focus loupe

struct FocusLoupe: View {
    let nightMode: Bool
    let sharpness: Double

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: DS.sm) {
                ZStack {
                    Circle().fill(Color(red: 0.02, green: 0.02, blue: 0.05))
                    // A single star, tightening as focus improves.
                    Circle()
                        .fill(RadialGradient(colors: [.white, .white.opacity(0.0)],
                                             center: .center, startRadius: 0,
                                             endRadius: 26 - sharpness * 18))
                        .frame(width: 60, height: 60)
                    Circle().strokeBorder(DS.accent(nightMode).opacity(0.7), lineWidth: 1)
                }
                .frame(width: 150, height: 150)
                .clipShape(Circle())

                Text("STAR SHARPNESS").label(9).foregroundStyle(DS.secondaryText(nightMode))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.surfaceRaised)
                        Capsule().fill(DS.accent(nightMode))
                            .frame(width: g.size.width * sharpness)
                    }
                }
                .frame(height: 6)
                Text("\(Int(sharpness * 100))%").readout(20, weight: .bold)
                    .foregroundStyle(DS.primaryText(nightMode))
                Text("HFD 2.4 px · turn focus until this bottoms out")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.secondaryText(nightMode))
            }
            .padding(DS.lg)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radius))
            .padding(.bottom, 260)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .allowsHitTesting(false)
    }
}

// MARK: - Histogram

/// Astro histogram: emphasises the low end, where nearly all the signal is.
struct HistogramStrip: View {
    let nightMode: Bool
    private let bins: [Double] = [0.95, 0.72, 0.48, 0.30, 0.19, 0.12, 0.08, 0.05,
                                  0.04, 0.03, 0.02, 0.02, 0.01, 0.01, 0.01, 0.02]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(bins.indices, id: \.self) { i in
                Capsule()
                    .fill(DS.primaryText(nightMode).opacity(0.55))
                    .frame(width: 3, height: max(2, bins[i] * 30))
            }
        }
        .frame(height: 30)
        .accessibilityLabel("Histogram: signal concentrated in shadows, no clipping")
    }
}
