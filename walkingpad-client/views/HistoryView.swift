import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var workout: Workout
    @State private var entries: [WorkoutSaveData] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("History")
                .font(.caption)
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("No workouts recorded yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                        GridRow {
                            Text(entry.date, format: .dateTime.day().month(.abbreviated))
                                .font(.caption2)
                                .gridColumnAlignment(.leading)
                            Text("\(entry.steps) steps")
                                .font(.caption2)
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(Self.durationFormatter.string(from: TimeInterval(entry.walkingSeconds)) ?? "")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .onAppear {
            entries = workout.loadAll().filter { $0.steps > 0 }.sorted { $0.date > $1.date }
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
