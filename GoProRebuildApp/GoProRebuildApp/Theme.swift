import SwiftUI

/// Design tokens from DESIGN.md.
///
/// Quik-feel chrome: near-black surfaces, one saturated blue accent, near-black
/// label on accent buttons for contrast. No GoPro marks.
enum Theme {
    // MARK: Surfaces
    static let background = Color(hex: 0x101213)
    static let surface = Color(hex: 0x181A1B)
    static let surfaceRaised = Color(hex: 0x22262A)

    // MARK: Text
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xCFD2D3)
    static let textMuted = Color(hex: 0xA3A8A9)

    // MARK: Accent
    static let accent = Color(hex: 0x00AEEF)
    static let accentDeep = Color(hex: 0x005DAC)
    static let onAccent = Color(hex: 0x0A0C0D)

    // MARK: Semantic
    static let record = Color(hex: 0xFF3B30)
    static let ok = Color(hex: 0x30D158)
    static let warn = Color(hex: 0xFF9F0A)

    // MARK: Metrics
    static let corner: CGFloat = 12
    static let tapTarget: CGFloat = 44
    static let rowHeight: CGFloat = 64
    static let shutterDiameter: CGFloat = 88
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

/// Primary action: accent fill, near-black label (white on `#00AEEF` is 2.6:1).
struct PrimaryButton: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
            .background(
                (enabled ? Theme.accent : Theme.surfaceRaised)
                    .opacity(configuration.isPressed ? 0.7 : 1.0),
                in: RoundedRectangle(cornerRadius: Theme.corner)
            )
            .foregroundStyle(enabled ? Theme.onAccent : Theme.textMuted)
    }
}

/// Secondary action: raised surface, white label.
struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: Theme.tapTarget)
            .background(
                Theme.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1.0),
                in: RoundedRectangle(cornerRadius: Theme.corner)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}

/// Raised card. Fixed padding keeps rows from jittering when text scales.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.surface)
            )
    }
}
