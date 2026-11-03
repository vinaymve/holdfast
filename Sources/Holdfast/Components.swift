// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct Chip: View {
    let title: String
    var symbol: String?
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

    private var format: IntegerFormatStyle<Int> {
        zeroPadded ? IntegerFormatStyle<Int>().precision(.integerLength(2)) : IntegerFormatStyle<Int>()
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("0", value: $value, format: format)
                .textFieldStyle(.plain)
                .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: value) { _, new in
                    let clamped = min(max(new, range.lowerBound), range.upperBound)
                    if clamped != new { value = clamped }
                    onChange()
                }
            Text(unit)
                .font(.title3)
                .foregroundStyle(.secondary)
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
