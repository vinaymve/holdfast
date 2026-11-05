// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

struct BlockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let block = model.activeBlock {
                    ActiveBlockCard(block: block)
                } else {
                    BlockHeader()
                    NewBlockCard()
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        // The idle screen has its own large heading, so the toolbar title would only repeat it.
        .navigationTitle(model.activeBlock == nil ? "" : "Block Running")
        .errorAlert(Bindable(model).errorMessage)
    }
}

private struct BlockHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New block")
                .font(Theme.display(34))
                .foregroundStyle(Theme.ink)
            Text("Choose what to block and for how long. A running block can't be ended early.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Starting a block

struct NewBlockCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Heading("What to block")
                    ProfilePicker()
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Heading("For how long")
                    LengthPicker()
                }
            }
            VStack(spacing: 10) {
                Button {
                    Task { await model.startBlock() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isBusy { Spinner() }
                        Text("Start block")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)

                Text(startHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension NewBlockCard {
    /// Explains the one-time setup right where it happens, instead of in a separate banner.
    fileprivate var startHint: String {
        switch model.helper {
        case .notInstalled:
            return "First time: you'll be asked for your admin password twice, once to set up the helper and once to start. You won't be able to turn the block off until the timer runs out."
        case .outdated:
            return "The helper will be updated first, so expect an extra admin prompt. You won't be able to turn the block off until the timer runs out."
        case .notRunning:
            return "The helper will be restarted first. You won't be able to turn the block off until the timer runs out."
        case .ready, .checking:
            return "You won't be able to turn the block off until the timer runs out."
        }
    }
}

struct ProfilePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.profiles) { profile in
                        Chip(title: profile.name, symbol: profile.symbol, isSelected: profile.id == model.selectedProfile?.id) {
                            model.selectProfile(profile.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if let profile = model.selectedProfile {
                HStack {
                    Text(summary(profile))
                        .font(.system(size: 13))
                        .foregroundStyle(profile.isEmpty ? Theme.warning : Theme.inkSecondary)
                    Spacer()
                    Button("Edit profile") { model.section = .profiles }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func summary(_ p: Profile) -> String {
        if p.isEmpty { return "This profile is empty. Add sites or apps to block." }
        var parts: [String] = []
        if p.isAllowlist {
            parts.append(p.entries.isEmpty ? "Everything blocked" : "Only \(p.entries.count) site\(p.entries.count == 1 ? "" : "s") allowed")
        } else if !p.entries.isEmpty {
            parts.append("\(p.entries.count) site\(p.entries.count == 1 ? "" : "s")")
        }
        if !p.apps.isEmpty { parts.append("\(p.apps.count) app\(p.apps.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Length picker (replaces the original slider)

struct LengthPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            SegmentedControl(options: [(LengthMode.duration, "For a duration"), (LengthMode.until, "Until a time")],
                             selection: $model.lengthMode)
                .onChange(of: model.lengthMode) { model.saveLengthChoice() }

            switch model.lengthMode {
            case .duration: DurationEditor()
            case .until: UntilEditor()
            }

            if let problem = model.lengthProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warning)
            } else {
                Label(model.plannedEndDescription, systemImage: "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct DurationEditor: View {
    @Environment(AppModel.self) private var model
    private let presets: [(String, Int)] = [("15m", 15), ("30m", 30), ("45m", 45), ("1h", 60), ("2h", 120), ("3h", 180), ("4h", 240), ("8h", 480)]

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 22) {
                NumberField(unit: model.hours == 1 ? "hour" : "hours", value: $model.hours, range: 0...168) { model.saveLengthChoice() }
                NumberField(unit: "min", value: $model.minutes, range: 0...59) { model.saveLengthChoice() }
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.1) { title, total in
                    Chip(title: title, isSelected: model.hours * 60 + model.minutes == total) {
                        model.setDuration(totalMinutes: total)
                    }
                }
            }
        }
    }
}

private struct UntilEditor: View {
    @Environment(AppModel.self) private var model
    private let presets: [(hour: Int, minute: Int)] = [(12, 0), (17, 0), (18, 0), (21, 0), (23, 0)]

    private var uses12Hour: Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
    }

    private var parts: (hour: Int, minute: Int) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: model.untilTime)
        return (c.hour ?? 0, c.minute ?? 0)
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: {
                let h = parts.hour
                return uses12Hour ? (h % 12 == 0 ? 12 : h % 12) : h
            },
            set: { new in
                let isPM = parts.hour >= 12
                let hour24 = uses12Hour ? (new % 12) + (isPM ? 12 : 0) : new
                model.setUntil(hour: min(23, max(0, hour24)), minute: parts.minute)
            })
    }

    private var minuteBinding: Binding<Int> {
        Binding(get: { parts.minute }, set: { model.setUntil(hour: parts.hour, minute: min(59, max(0, $0))) })
    }

    private var pmBinding: Binding<Bool> {
        Binding(get: { parts.hour >= 12 },
                set: { isPM in model.setUntil(hour: (parts.hour % 12) + (isPM ? 12 : 0), minute: parts.minute) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                NumberField(unit: "", value: hourBinding, range: uses12Hour ? 1...12 : 0...23)
                Text(":").font(Theme.display(30, weight: .medium)).foregroundStyle(Theme.inkSecondary)
                NumberField(unit: "", value: minuteBinding, range: 0...59, zeroPadded: true)
                if uses12Hour {
                    SegmentedControl(options: [(false, "AM"), (true, "PM")], selection: pmBinding)
                        .frame(width: 120)
                }
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.hour) { preset in
                    Chip(title: label(preset.hour, preset.minute), isSelected: parts == (preset.hour, preset.minute)) {
                        model.setUntil(hour: preset.hour, minute: preset.minute)
                    }
                }
            }
        }
    }

    private func label(_ hour: Int, _ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - A running block

struct ActiveBlockCard: View {
    @Environment(AppModel.self) private var model
    let block: ActiveBlock
    @State private var showAddSites = false
    @State private var showExtend = false

    var body: some View {
        let remaining = block.remaining(at: model.now)
        VStack(spacing: 16) {
            Card(padding: 28) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 8) {
                        StatusDot()
                        Text("Blocking" + (block.profileName.map { " · \($0)" } ?? ""))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.ink)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.clock(remaining))
                            .font(Theme.display(72, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .contentTransition(.numericText(countsDown: true))
                        Text(remaining > 0 ? "remaining" : "confirming the time…")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.inkSecondary)
                    }

                    VStack(spacing: 8) {
                        TimeBar(progress: block.progress(at: model.now))
                        HStack {
                            Text("Started \(block.startDate.formatted(date: .omitted, time: .shortened))")
                            Spacer()
                            Text("Ends \(endText)")
                        }
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                    }

                    HStack(spacing: 10) {
                        Button { showAddSites = true } label: { HStack(spacing: 6) { Image(systemName: "plus"); Text("Add sites") } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(block.isAllowlist || model.isBusy)
                            .help(block.isAllowlist ? "Sites can't be added to an allowlist block." : "Add more sites to this block")
                        Button { showExtend = true } label: { HStack(spacing: 6) { Image(systemName: "clock"); Text("Extend") } }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.isBusy)
                            .popover(isPresented: $showExtend, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach([(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours")], id: \.0) { minutes, title in
                                        Button(title) {
                                            showExtend = false
                                            Task { await model.extend(byMinutes: minutes) }
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                }
                                .padding(6)
                                .frame(width: 160)
                            }
                        Spacer()
                        Text(startedText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Heading(block.isAllowlist ? "Allowed sites" : "Blocked sites")
                        Spacer()
                        Text(block.isAllowlist ? "Everything else is blocked" : "\(block.entries.count) total")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if block.entries.isEmpty && !block.isAllowlist {
                        Text("No sites in this block.").foregroundStyle(Theme.inkSecondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(block.entries.prefix(40), id: \.self) { Tag(text: $0) }
                            if block.entries.count > 40 { Tag(text: "+\(block.entries.count - 40) more") }
                        }
                    }
                    if !block.apps.isEmpty {
                        Divider()
                        Heading("Blocked apps")
                        FlowLayout(spacing: 6) {
                            ForEach(block.apps, id: \.id) { Tag(text: $0.name) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSites) { AddSitesSheet() }
    }

    private var startedText: String {
        switch block.source {
        case .manual: return "Manual block"
        case .schedule(_, let name): return "Schedule: \(name)"
        }
    }

    private var endText: String {
        let cal = Calendar.current
        let end = block.displayEnd
        let time = end.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(end) { return time }
        if cal.isDateInTomorrow(end) { return "tomorrow \(time)" }
        return end.formatted(.dateTime.weekday(.abbreviated).month().day()) + " " + time
    }
}

struct AddSitesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add sites to the running block").font(.headline)
            Text("One per line. Once added, they can't be removed until the block ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Sites") {
                    Task {
                        await model.addSites(text)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}


/// Small indeterminate spinner drawn in SwiftUI. The AppKit-backed `ProgressView` logs "Invalid Configuration" faults
/// when it sits inside a button that is scaling or resizing, which happens while the helper installs.
struct Spinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.8)
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityLabel("Working")
    }
}
