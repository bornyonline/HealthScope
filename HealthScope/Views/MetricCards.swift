import SwiftUI
import Charts

struct LineMetricCard: View {
    let title: String
    let unitLabel: String
    let points: [TimeValuePoint]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if points.isEmpty {
                ContentUnavailableView("No data", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(unitLabel, point.value)
                    )
                    .foregroundStyle(color)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value(unitLabel, point.value)
                    )
                    .foregroundStyle(color.opacity(0.18))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6))
                }
                .frame(height: 220)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct BloodPressureCard: View {
    let points: [BloodPressurePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blood Pressure")
                .font(.headline)
            if points.isEmpty {
                ContentUnavailableView("No data", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Systolic", point.systolic)
                    )
                    .foregroundStyle(.red)
                    .symbol(.circle)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Diastolic", point.diastolic)
                    )
                    .foregroundStyle(.orange)
                    .symbol(.square)
                }
                .chartLegend(position: .bottom)
                .chartForegroundStyleScale([
                    "Systolic": Color.red,
                    "Diastolic": Color.orange
                ])
                .frame(height: 220)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ActivityCard: View {
    let points: [ActivityPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activities")
                .font(.headline)
            if points.isEmpty {
                ContentUnavailableView("No workouts", systemImage: "figure.run")
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else {
                Chart(points.prefix(8)) { point in
                    BarMark(
                        x: .value("Minutes", point.minutes),
                        y: .value("Activity", point.name)
                    )
                    .foregroundStyle(.teal.gradient)
                }
                .frame(height: 220)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
