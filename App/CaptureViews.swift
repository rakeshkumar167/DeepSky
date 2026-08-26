import SwiftUI

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
