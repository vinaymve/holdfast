// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

struct BlockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let block = model.activeBlock {
                    ActiveBlockCard(block: block)
                } else {
                    NewBlockCard()
                }
            }
            .frame(maxWidth: 560)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.activeBlock == nil ? "New Block" : "Block Running")
        .errorAlert(Bindable(model).errorMessage)
    }
}

// MARK: - Starting a block

struct NewBlockCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What to block").font(.headline)
                    ProfilePicker()
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("For how long").font(.headline)
                    LengthPicker()
                }
                VStack(spacing: 8) {
                    Button {
                        Task { await model.startBlock() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Text("Start Block").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)

                    Text(startHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
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
                        .font(.callout)
                        .foregroundStyle(profile.isEmpty ? Color.orange : Color.secondary)
                    Spacer()
                    Button("Edit…") { model.section = .profiles }
                        .buttonStyle(.link)
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
            Picker("Length", selection: $model.lengthMode) {
                Text("For a duration").tag(LengthMode.duration)
                Text("Until a time").tag(LengthMode.until)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: model.lengthMode) { model.saveLengthChoice() }

            switch model.lengthMode {
            case .duration: DurationEditor()
            case .until: UntilEditor()
            }

            if let problem = model.lengthProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Label(model.plannedEndDescription, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                Text(":").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                NumberField(unit: "", value: minuteBinding, range: 0...59, zeroPadded: true)
                if uses12Hour {
                    Picker("", selection: pmBinding) {
                        Text("AM").tag(false)
                        Text("PM").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 96)
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

    var body: some View {
        let remaining = block.remaining(at: model.now)
        VStack(spacing: 18) {
            Card {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.08), lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: block.progress(at: model.now))
                            .stroke(Color.accentColor.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: model.now)
                        VStack(spacing: 4) {
                            Text(Format.clock(remaining))
                                .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                            Text(remaining > 0 ? "remaining" : "confirming the time…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 236, height: 236)
                    .padding(.top, 4)

                    Text("Ends \(endText) · \(startedText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button { showAddSites = true } label: { Label("Add Sites…", systemImage: "plus") }
                            .disabled(block.isAllowlist || model.isBusy)
                            .help(block.isAllowlist ? "Sites can't be added to an allowlist block." : "Add more sites to this block")
                        Menu {
                            ForEach([(15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours")], id: \.0) { minutes, title in
                                Button(title) { Task { await model.extend(byMinutes: minutes) } }
                            }
                        } label: { Label("Extend", systemImage: "clock.badge.plus") }
                            .menuStyle(.button)
                            .fixedSize()
                            .disabled(model.isBusy)
                        Spacer(minLength: 0)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(block.isAllowlist ? "Allowed sites" : "Blocked sites").font(.headline)
                        Spacer()
                        Text(block.isAllowlist ? "Everything else is blocked" : "\(block.entries.count) total")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if block.entries.isEmpty && !block.isAllowlist {
                        Text("No sites in this block.").foregroundStyle(.secondary)
                    } else {
                        Text(block.entries.prefix(30).joined(separator: "  ·  ") + (block.entries.count > 30 ? "  ·  +\(block.entries.count - 30) more" : ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !block.apps.isEmpty {
                        Divider()
                        Text("Blocked apps").font(.headline)
                        Text(block.apps.map(\.name).joined(separator: "  ·  "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSites) { AddSitesSheet() }
    }

    private var startedText: String {
        switch block.source {
        case .manual: return "started manually"
        case .schedule(_, let name): return "started by schedule “\(name)”"
        }
    }

    private var endText: String {
        let cal = Calendar.current
        let end = block.displayEnd
        let time = end.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(end) { return "today at \(time)" }
        if cal.isDateInTomorrow(end) { return "tomorrow at \(time)" }
        return end.formatted(.dateTime.weekday(.abbreviated).month().day()) + " at " + time
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
