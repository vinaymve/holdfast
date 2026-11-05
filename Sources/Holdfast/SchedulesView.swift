// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import HoldfastCore

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Schedule?
    @State private var isNew = false

    private var schedules: [Schedule] { model.state.schedules }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if schedules.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No schedules yet")
                            .font(Theme.display(28))
                            .foregroundStyle(Theme.ink)
                        Text("A schedule starts a block on the days and times you pick, for example weekdays 9 to 5. Schedules keep running when this app is closed.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(maxWidth: 420, alignment: .leading)
                        Button { beginNew() } label: { Text("New schedule") }
                            .buttonStyle(PrimaryButtonStyle(compact: true))
                            .frame(width: 160)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } else {
                    ForEach(schedules) { schedule in
                        ScheduleRow(schedule: schedule,
                                    onToggle: { enabled in
                                        var updated = schedule
                                        updated.enabled = enabled
                                        replace(updated)
                                    },
                                    onEdit: { editing = schedule; isNew = false },
                                    onDelete: { remove(schedule) })
                    }
                }
            }
            .frame(maxWidth: 620)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Schedules")
        .toolbar {
            ToolbarItem {
                Button { beginNew() } label: { Label("New Schedule", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditor(schedule: schedule, isNew: isNew) { saved in
                if isNew { save(schedules + [saved]) } else { replace(saved) }
            }
        }
        .errorAlert(Bindable(model).errorMessage)
    }

    private func beginNew() {
        guard let profile = model.selectedProfile ?? model.profiles.first else { return }
        isNew = true
        editing = Schedule(name: "Work hours", weekdays: Schedule.weekdayNumbers, startHour: 9, startMinute: 0,
                           durationMinutes: 8 * 60, profile: profile, options: model.currentOptions())
    }

    private func replace(_ schedule: Schedule) {
        save(schedules.map { $0.id == schedule.id ? schedule : $0 })
    }

    private func remove(_ schedule: Schedule) {
        save(schedules.filter { $0.id != schedule.id })
    }

    private func save(_ list: [Schedule]) {
        Task { _ = await model.saveSchedules(list) }
    }
}

private struct ScheduleRow: View {
    @Environment(AppModel.self) private var model
    let schedule: Schedule
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Card(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                Toggle("", isOn: Binding(get: { schedule.enabled }, set: onToggle))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.isBusy)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(schedule.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        if schedule.enabled, schedule.window(containing: model.now) != nil {
                            HStack(spacing: 5) { StatusDot(); Text("Active now").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink) }
                        }
                    }
                    Text("\(daysText) · \(timeText)").font(.system(size: 13)).foregroundStyle(Theme.inkSecondary)
                    HStack(spacing: 6) {
                        Image(systemName: schedule.profile.symbol)
                        Text(schedule.profile.name)
                        if let next = nextText { Text("· \(next)") }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                }
                .opacity(schedule.enabled ? 1 : 0.6)
                Spacer()
                Button("Edit", action: onEdit).buttonStyle(SecondaryButtonStyle()).disabled(model.isBusy)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy)
                    .help("Delete schedule")
            }
        }
    }

    private var daysText: String {
        let days = Set(schedule.weekdays)
        if days == Set(1...7) { return "Every day" }
        if days == Set(Schedule.weekdayNumbers) { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return days.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    private var timeText: String {
        let end = schedule.endTimeOfDay
        func format(_ h: Int, _ m: Int) -> String {
            (Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date())
                .formatted(date: .omitted, time: .shortened)
        }
        return "\(format(schedule.startHour, schedule.startMinute)) – \(format(end.hour, end.minute))"
    }

    private var nextText: String? {
        guard schedule.enabled else { return "paused" }
        if let window = schedule.window(containing: model.now) {
            return "active until \(window.end.formatted(date: .omitted, time: .shortened))"
        }
        guard let next = schedule.nextStart(after: model.now) else { return nil }
        let cal = Calendar.current
        let day = cal.isDateInToday(next) ? "today" : cal.isDateInTomorrow(next) ? "tomorrow" : next.formatted(.dateTime.weekday(.wide))
        return "next \(day) at \(next.formatted(date: .omitted, time: .shortened))"
    }
}

private struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let onSave: (Schedule) -> Void

    @State private var schedule: Schedule
    @State private var start: Date
    @State private var end: Date
    @State private var profileID: UUID

    init(schedule: Schedule, isNew: Bool, onSave: @escaping (Schedule) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _schedule = State(initialValue: schedule)
        let cal = Calendar.current
        let startDate = cal.date(bySettingHour: schedule.startHour, minute: schedule.startMinute, second: 0, of: Date()) ?? Date()
        _start = State(initialValue: startDate)
        _end = State(initialValue: startDate.addingTimeInterval(TimeInterval(schedule.durationMinutes) * 60))
        _profileID = State(initialValue: schedule.profile.id)
    }

    private var durationMinutes: Int {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: start)
        let e = cal.dateComponents([.hour, .minute], from: end)
        let diff = ((e.hour ?? 0) * 60 + (e.minute ?? 0)) - ((s.hour ?? 0) * 60 + (s.minute ?? 0))
        return (diff + 1_440) % 1_440
    }

    private var problem: String? {
        if schedule.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the schedule a name." }
        if schedule.weekdays.isEmpty { return "Pick at least one day." }
        if durationMinutes == 0 { return "The start and end times must be different." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New Schedule" : "Edit Schedule").font(.title3.bold())

            Form {
                TextField("Name", text: $schedule.name)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Days")
                    HStack(spacing: 6) {
                        ForEach(orderedWeekdays, id: \.number) { day in
                            Chip(title: day.short, isSelected: schedule.weekdays.contains(day.number)) {
                                if schedule.weekdays.contains(day.number) {
                                    schedule.weekdays.removeAll { $0 == day.number }
                                } else {
                                    schedule.weekdays.append(day.number)
                                }
                            }
                        }
                    }
                }

                DatePicker("Starts at", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("Ends at", selection: $end, displayedComponents: .hourAndMinute)
                if durationMinutes > 0 {
                    LabeledContent("Length", value: Format.duration(TimeInterval(durationMinutes) * 60) + (end < start || isOvernight ? " (ends next day)" : ""))
                }

                Picker("Profile", selection: $profileID) {
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
            }
            .formStyle(.columns)

            Text("The schedule uses a copy of the profile as it is now. If you edit the profile later, save the schedule again to pick up the changes. Saving asks for your admin password.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || model.isBusy)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var isOvernight: Bool { durationMinutes > 0 && (start.timeIntervalSinceReferenceDate > end.timeIntervalSinceReferenceDate) }

    private var orderedWeekdays: [(number: Int, short: String)] {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        return (0..<7).map { offset in
            let number = (cal.firstWeekday - 1 + offset) % 7 + 1
            return (number, symbols[number - 1])
        }
    }

    private func commit() {
        let cal = Calendar.current
        let s = cal.dateComponents([.hour, .minute], from: start)
        var saved = schedule
        saved.startHour = s.hour ?? 9
        saved.startMinute = s.minute ?? 0
        saved.durationMinutes = durationMinutes
        saved.weekdays = Array(Set(schedule.weekdays)).sorted()
        if let profile = model.profiles.first(where: { $0.id == profileID }) { saved.profile = profile }
        onSave(saved)
        dismiss()
    }
}
