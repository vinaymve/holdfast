// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import Charts
import HoldfastCore

struct StatsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let stats = model.stats
        ScrollView {
            VStack(spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    StatTile(title: "Time blocked", value: hoursText(stats.totalSeconds))
                    StatTile(title: "Blocks", value: "\(stats.blockCount)")
                    StatTile(title: "Current streak", value: "\(stats.currentStreakDays) day\(stats.currentStreakDays == 1 ? "" : "s")")
                    StatTile(title: "Longest block", value: Format.duration(stats.longestSeconds))
                }

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Heading("Last 14 days")
                        Chart(stats.daily, id: \.day) { item in
                            BarMark(x: .value("Day", item.day, unit: .day), y: .value("Hours", item.seconds / 3600))
                                .foregroundStyle(Calendar.current.isDateInToday(item.day) ? Theme.accent : Theme.ink.opacity(0.78))
                                .cornerRadius(2)
                        }
                        .chartYAxisLabel("hours")
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                                AxisValueLabel(format: .dateTime.day())
                            }
                        }
                        .frame(height: 180)
                        Text("Longest streak: \(stats.longestStreakDays) day\(stats.longestStreakDays == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Heading("Recent blocks")
                        if model.state.history.isEmpty {
                            Text("Finished blocks will show up here.").foregroundStyle(.secondary)
                        }
                        ForEach(model.state.history.suffix(12).reversed()) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.profileName ?? "Custom block")
                                    Text(entry.startDate.formatted(date: .abbreviated, time: .shortened) + " · " + entry.source.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Format.duration(entry.duration)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: 620)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Stats")
    }

    private func hoursText(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? String(format: "%.1f h", seconds / 3600) : Format.duration(seconds)
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
                Text(value)
                    .font(Theme.display(28, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
    }
}
