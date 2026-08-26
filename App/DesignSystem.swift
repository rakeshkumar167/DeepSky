import SwiftUI

/// Design tokens for DeepSky.
///
/// Two decisions drive everything here, and both come from the use context —
/// a person standing in a dark field at 3am — rather than from taste:
///
/// 1. **True black, not dark grey.** OLED pixels are genuinely off at #000, so
///    the screen emits almost nothing. A "dark grey" theme lights up the user's
///    face and the surrounding area.
/// 2. **Night mode is red.** Scotopic (rod-based) vision takes 20-30 minutes to
///    build and white or blue light destroys it in seconds. Red light at low
///    intensity leaves it largely intact, which is why observatory and telescope
///    software has shipped red modes for decades. This is a functional
///    requirement, not a theme.
enum DS {

    // MARK: - Palette

    /// The accent hue. In night mode everything chromatic collapses to red.
    static func accent(_ night: Bool) -> Color {
        night ? Color(red: 1.00, green: 0.23, blue: 0.19) : Color(red: 0.35, green: 0.71, blue: 1.00)
    }

    /// Primary readout text. Kept below pure white even in standard mode —
    /// full-intensity white is unnecessary against true black and costs
    /// dark adaptation.
    static func primaryText(_ night: Bool) -> Color {
        night ? Color(red: 1.00, green: 0.30, blue: 0.25) : Color(white: 0.94)
    }

    static func secondaryText(_ night: Bool) -> Color {
        night ? Color(red: 0.72, green: 0.20, blue: 0.16) : Color(white: 0.62)
    }

    static func hairline(_ night: Bool) -> Color {
        night ? Color(red: 0.40, green: 0.10, blue: 0.08) : Color(white: 0.22)
    }

    static let background = Color.black
    /// Panels sit just above true black so edges read without emitting light.
    static let surface = Color(white: 0.07)
    static let surfaceRaised = Color(white: 0.12)

    static let good = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let bad = Color(red: 1.00, green: 0.36, blue: 0.33)

    /// Status colours must survive night mode too — but they stay
    /// distinguishable by icon and label, never by colour alone.
    static func status(_ level: Int, night: Bool) -> Color {
        guard !night else { return primaryText(night) }
        switch level {
        case 0: return good
        case 1: return warn
        default: return bad
        }
    }

    // MARK: - Spacing — 4/8pt rhythm

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32

    /// Well above the 44pt minimum. Cold hands, gloves, no light, and the
    /// cost of a mis-tap is a ruined 30-minute session.
    static let captureButton: CGFloat = 84
    static let controlHeight: CGFloat = 56

    static let radius: CGFloat = 14
}

/// Numeric readouts use tabular figures so digits do not shift as values
/// change during a live capture.
extension View {
    func readout(_ size: CGFloat = 17, weight: Font.Weight = .semibold) -> some View {
        self.font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
    }

    func label(_ size: CGFloat = 11) -> some View {
        self.font(.system(size: size, weight: .medium))
            .textCase(.uppercase)
            .kerning(0.6)
    }
}
