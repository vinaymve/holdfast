// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import AppKit

/// Design system, "Field Notes": warm paper neutrals, near-black ink, and a single vermilion accent that only ever marks
/// the primary action and a live block. Flat surfaces with hairline borders; no gradients, glows or glass.
///
/// Contrast (WCAG): ink on paper 15:1, secondary text on paper 5.2:1 (dark 6.6:1), white on accent 4.9:1; in dark mode the
/// accent is lighter and carries dark ink text (4.9:1).
enum Theme {
    // Surfaces, light / dark. Dark surfaces step lighter as they rise, by larger steps than in light mode.
    static let paper = dynamic(0xF5F2EB, 0x1B1A18)        // window
    static let sidebar = dynamic(0xEDE9DF, 0x161513)
    static let surface = dynamic(0xFBF9F4, 0x252321)      // cards
    static let raised = dynamic(0xFFFFFF, 0x302E2B)       // selected segment, hovered row
    static let track = dynamic(0xE6E1D5, 0x121110)        // segmented-control and progress track
    static let hairline = dynamic(0xDAD4C6, 0x3B3834)

    // Text
    static let ink = dynamic(0x1C1A17, 0xECE8E0)
    static let inkSecondary = dynamic(0x6B665C, 0xA7A196)

    // The one accent, and the text colour that sits on it.
    static let accent = dynamic(0xC8431F, 0xE8673F)
    static let accentHover = dynamic(0xB43A19, 0xF07A55)
    static let accentPressed = dynamic(0x9E3315, 0xD95A33)
    static let onAccent = dynamic(0xFFFFFF, 0x1B1A18)

    // Semantic
    static let warning = dynamic(0x9A5B00, 0xE5A445)

    static let cardRadius: CGFloat = 12
    /// Inner controls: card radius minus the card's 4pt inset step, kept concentric.
    static let controlRadius: CGFloat = 8
    static let tagRadius: CGFloat = 6

    /// Display type uses the system serif (New York) for the page title, the countdown and the stat figures. Everything else is SF.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// 1pt border in the hairline colour. Elevation is a border or nothing, never a shadow.
    func hairline(radius: CGFloat, color: Color = Theme.hairline) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: 1))
    }
}

// MARK: - Buttons

/// The primary call to action. Hover and pressed each step visibly off the rest colour.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, compact: compact)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let fill = configuration.isPressed ? Theme.accentPressed : hovering ? Theme.accentHover : Theme.accent
            configuration.label
                .font(.system(size: compact ? 13 : 16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.vertical, compact ? 7 : 13)
                .padding(.horizontal, compact ? 8 : 20)
                .frame(maxWidth: .infinity)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Everything that is not the primary action: a clear outline so it reads as a button at rest.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(configuration.isPressed ? Theme.track : hovering ? Theme.raised : Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .hairline(radius: Theme.controlRadius)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Press-in feedback for custom tappable views.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Small pieces

/// Section heading inside a card: sentence case, no icon tile, no eyebrow.
struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.ink)
    }
}

/// A site, app or fact shown as a small outlined tag. Outlined, not filled, so a wall of them stays quiet.
struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .hairline(radius: Theme.tagRadius)
    }
}

/// Live-block marker. Static: it states a fact, it doesn't need to pulse.
struct StatusDot: View {
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 8, height: 8)
    }
}

/// Wraps its children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            width = max(width, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Thin progress bar backed by real elapsed time.
struct TimeBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Block progress")
        .accessibilityValue("\(Int(progress * 100)) percent elapsed")
    }
}
