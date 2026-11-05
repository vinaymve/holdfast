// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = Theme.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .hairline(radius: radius)
    }
}

/// Selectable preset. The selected chip is inverted ink, so accent colour stays reserved for the primary action.
/// Tracks whether the last input was the keyboard, so focus rings show for Tab navigation but not when the window
/// simply hands initial focus to the first control.
enum KeyboardNav {
    static var lastInputWasKey = false
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            lastInputWasKey = event.type == .keyDown
            return event
        }
    }
}

struct Chip: View {
    let title: String
    var symbol: String?
    var isSelected = false
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(isSelected ? Theme.paper : Theme.ink)
            .background(isSelected ? Theme.ink : hovering ? Theme.raised : Theme.paper,
                        in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .hairline(radius: Theme.controlRadius, color: isSelected ? Theme.ink : Theme.hairline)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(PressableStyle())
        .focusEffectDisabled()
        .focused($focused)
        .overlay {
            // Keyboard focus ring in the app's ink colour, drawn inside the chip so no parent can clip it. On a selected
            // (ink) chip the ring would vanish, so it gets a paper line just inside it.
            if focused && KeyboardNav.lastInputWasKey {
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: 2)
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.controlRadius - 2, style: .continuous)
                        .strokeBorder(Theme.paper, lineWidth: 1.5)
                        .padding(2)
                }
            }
        }
        .onHover { hovering = $0 }
        .onAppear { KeyboardNav.start() }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Segmented control: raised thumb on a recessed track.
struct SegmentedControl<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selection = value }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == value ? Theme.ink : Theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: Theme.controlRadius - 2, style: .continuous)
                                    .fill(Theme.raised)
                                    .hairline(radius: Theme.controlRadius - 2)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: Theme.controlRadius + 1, style: .continuous))
    }
}

/// Large number box with a stepper. Typing is clamped on commit, and out-of-range values never reach the model.
struct NumberField: View {
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// Show at least two digits ("05"), for minutes in a clock time.
    var zeroPadded = false
    var onChange: () -> Void = {}
    @FocusState private var focused: Bool

    private var format: IntegerFormatStyle<Int> {
        zeroPadded ? IntegerFormatStyle<Int>().precision(.integerLength(2)) : IntegerFormatStyle<Int>()
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("0", value: $value, format: format)
                .textFieldStyle(.plain)
                .font(Theme.display(34, weight: .medium))
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(width: 78)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Theme.hairline, lineWidth: focused ? 2 : 1))
                .onChange(of: value) { _, new in
                    let clamped = min(max(new, range.lowerBound), range.upperBound)
                    if clamped != new { value = clamped }
                    onChange()
                }
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
    }
}

extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
