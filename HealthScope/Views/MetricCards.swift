import SwiftUI
import Charts

struct MetricSummary: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

struct MetricGuide: Identifiable {
    let label: String
    let symbol: String

    var id: String { label }
}

struct MetricCardShell<ChartContent: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let summaries: [MetricSummary]
    let period: String
    let guides: [MetricGuide]
    let isEmpty: Bool
    let insufficientMessage: String?
    let chartHeight: CGFloat
    let accessibilitySummary: String
    @ViewBuilder let chartContent: () -> ChartContent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleView
                    Spacer(minLength: 8)
                    periodView
                }

                VStack(alignment: .leading, spacing: 8) {
                    titleView
                    periodView
                }
            }

            if !summaries.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(summaries) { summary in
                            summaryView(summary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summaries) { summary in
                            summaryView(summary)
                        }
                    }
                }
            }

            if isEmpty {
                ContentUnavailableView {
                    Label("No data in this period", systemImage: systemImage)
                } description: {
                    Text("Add an entry or import data to begin tracking.")
                }
                .frame(maxWidth: .infinity)
                .frame(height: chartHeight)
            } else {
                chartContent()
                    .frame(height: chartHeight)
                    .accessibilityLabel(Text("\(title) chart"))
                    .accessibilityValue(Text(accessibilitySummary))

                if let insufficientMessage {
                    Label(insufficientMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !guides.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        ForEach(guides) { guide in
                            guideView(guide)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(guides) { guide in
                            guideView(guide)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func summaryView(_ summary: MetricSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(summary.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.label)
        .accessibilityValue(summary.value)
    }

    private var titleView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var periodView: some View {
        Text(period)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private func guideView(_ guide: MetricGuide) -> some View {
        Label(guide.label, systemImage: guide.symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BloodPressureCard: View {
    let points: [BloodPressurePoint]
    var period = "Selected period"
    var chartHeight: CGFloat = 150
    var selection: Binding<Date?>? = nil

    private var latest: BloodPressurePoint? { points.last }

    private var average: (systolic: Double, diastolic: Double)? {
        guard !points.isEmpty else { return nil }
        return (
            points.map(\.systolic).reduce(0, +) / Double(points.count),
            points.map(\.diastolic).reduce(0, +) / Double(points.count)
        )
    }

    var body: some View {
        MetricCardShell(
            title: "Blood Pressure",
            subtitle: "Daily average - systolic over diastolic",
            systemImage: "heart.text.square.fill",
            tint: .red,
            summaries: summaries,
            period: period,
            guides: [
                MetricGuide(label: "Triangle: systolic", symbol: "triangle.fill"),
                MetricGuide(label: "Square: diastolic", symbol: "square.fill")
            ],
            isEmpty: points.isEmpty,
            insufficientMessage: points.count == 1 ? "One day recorded; add another day to reveal change." : nil,
            chartHeight: chartHeight,
            accessibilitySummary: bloodPressureAccessibility
        ) {
            BloodPressureChart(points: points, selection: selection)
        }
    }

    private var summaries: [MetricSummary] {
        guard let latest, let average else { return [] }
        return [
            MetricSummary(label: "Latest daily average", value: "\(latest.systolic.whole)/\(latest.diastolic.whole) mmHg"),
            MetricSummary(label: "Period average", value: "\(average.systolic.whole)/\(average.diastolic.whole)")
        ]
    }

    private var bloodPressureAccessibility: String {
        guard let latest, let average else { return "No blood pressure data." }
        return "\(points.count) daily readings. Latest daily average \(latest.systolic.whole) over \(latest.diastolic.whole) millimeters of mercury. Period average \(average.systolic.whole) over \(average.diastolic.whole)."
    }
}

struct BloodPressureChart: View {
    let points: [BloodPressurePoint]
    var selection: Binding<Date?>? = nil

    private var selectedPoint: BloodPressurePoint? {
        nearestPoint(to: selection?.wrappedValue, in: points, date: \.date)
    }

    var body: some View {
        selectableChart
    }

    @ViewBuilder
    private var selectableChart: some View {
        let chart = Chart {
            ForEach(points) { point in
                RuleMark(
                    x: .value("Date", point.date),
                    yStart: .value("Diastolic", point.diastolic),
                    yEnd: .value("Systolic", point.systolic)
                )
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))

                PointMark(x: .value("Date", point.date), y: .value("Systolic", point.systolic))
                    .foregroundStyle(.red)
                    .symbol(.triangle)
                    .symbolSize(55)

                PointMark(x: .value("Date", point.date), y: .value("Diastolic", point.diastolic))
                    .foregroundStyle(.orange)
                    .symbol(.square)
                    .symbolSize(45)
            }

            if let selectedPoint {
                RuleMark(x: .value("Selected date", selectedPoint.date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4) {
                        SelectionCallout(
                            date: selectedPoint.date,
                            value: "\(selectedPoint.systolic.whole)/\(selectedPoint.diastolic.whole) mmHg"
                        )
                    }
            }
        }
        .chartXAxis { compactDateAxis }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine()
                AxisValueLabel()
            }
        }

        if let selection {
            chart.chartXSelection(value: selection)
        } else {
            chart
        }
    }
}

struct TimeMetricCard: View {
    @EnvironmentObject private var preferences: AppPreferences

    let metric: MetricType
    let points: [TimeValuePoint]
    var period = "Selected period"
    var chartHeight: CGFloat = 150
    var selection: Binding<Date?>? = nil

    private var latest: TimeValuePoint? { points.last }
    private var average: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.value).reduce(0, +) / Double(points.count)
    }

    var body: some View {
        MetricCardShell(
            title: metric.cardTitle,
            subtitle: metric.cardSubtitle,
            systemImage: metric.systemImage,
            tint: metric.tint,
            summaries: summaries,
            period: period,
            guides: metric.guides(for: preferences.measurementSystem),
            isEmpty: points.isEmpty,
            insufficientMessage: points.count == 1 ? "One day recorded; add another day to reveal a trend." : nil,
            chartHeight: chartHeight,
            accessibilitySummary: accessibilitySummary
        ) {
            TimeMetricChart(metric: metric, points: points, selection: selection)
        }
    }

    private var summaries: [MetricSummary] {
        guard let latest, let average else { return [] }
        return [
            MetricSummary(label: metric.latestLabel, value: metric.formatted(latest.value, measurementSystem: preferences.measurementSystem)),
            MetricSummary(label: metric.averageLabel, value: metric.formatted(average, measurementSystem: preferences.measurementSystem))
        ]
    }

    private var accessibilitySummary: String {
        guard let latest, let average else { return "No \(metric.cardTitle.lowercased()) data." }
        return "\(points.count) daily values. \(metric.latestLabel): \(metric.spoken(latest.value, measurementSystem: preferences.measurementSystem)). \(metric.averageLabel): \(metric.spoken(average, measurementSystem: preferences.measurementSystem))."
    }
}

struct TimeMetricChart: View {
    @EnvironmentObject private var preferences: AppPreferences

    let metric: MetricType
    let points: [TimeValuePoint]
    var selection: Binding<Date?>? = nil

    private var selectedPoint: TimeValuePoint? {
        nearestPoint(to: selection?.wrappedValue, in: chartPoints, date: \.date)
    }

    private var chartPoints: [TimeValuePoint] {
        guard metric == .bloodGlucose else { return points }
        return points.map {
            TimeValuePoint(
                id: $0.id,
                date: $0.date,
                value: preferences.measurementSystem.displayGlucose(fromMilligramsPerDeciliter: $0.value),
                source: $0.source
            )
        }
    }

    var body: some View {
        selectableChart
    }

    @ViewBuilder
    private var selectableChart: some View {
        let chart = Chart {
            metricMarks

            if let selectedPoint {
                RuleMark(x: .value("Selected date", selectedPoint.date))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 4) {
                        SelectionCallout(
                            date: selectedPoint.date,
                            value: metric.formattedDisplayValue(selectedPoint.value, measurementSystem: preferences.measurementSystem)
                        )
                    }
            }
        }
        .chartXAxis { compactDateAxis }
        .chartYAxis {
            if metric == .spo2 {
                AxisMarks(position: .leading, values: [90, 95, 100]) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                }
            } else {
                AxisMarks(position: .leading) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
        }
        .chartYScale(domain: metric.yDomain(for: chartPoints, measurementSystem: preferences.measurementSystem))

        if let selection {
            chart.chartXSelection(value: selection)
        } else {
            chart
        }
    }

    @ChartContentBuilder
    private var metricMarks: some ChartContent {
        switch metric {
        case .bloodGlucose:
            let guideLow = preferences.measurementSystem.displayGlucose(fromMilligramsPerDeciliter: 70)
            let guideHigh = preferences.measurementSystem.displayGlucose(fromMilligramsPerDeciliter: 180)
            RectangleMark(
                xStart: nil,
                xEnd: nil,
                yStart: .value("Guide low", guideLow),
                yEnd: .value("Guide high", guideHigh)
            )
            .foregroundStyle(.pink.opacity(0.08))

            RuleMark(y: .value("Guide low", guideLow))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            RuleMark(y: .value("Guide high", guideHigh))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))

            ForEach(glucoseSegments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Glucose", point.value),
                        series: .value("Continuous segment", segment.id)
                    )
                    .foregroundStyle(.pink)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            ForEach(chartPoints) { point in
                PointMark(x: .value("Date", point.date), y: .value("Glucose", point.value))
                    .foregroundStyle(.pink)
                    .symbol(.circle)
                    .symbolSize(32)
            }

        case .spo2:
            RuleMark(y: .value("90 percent guide", 90))
                .foregroundStyle(.orange)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            RuleMark(y: .value("95 percent guide", 95))
                .foregroundStyle(.cyan)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [7, 4]))
            ForEach(chartPoints) { point in
                LineMark(x: .value("Date", point.date), y: .value("Oxygen saturation", point.value))
                    .foregroundStyle(.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Date", point.date), y: .value("Oxygen saturation", point.value))
                    .foregroundStyle(.cyan)
                    .symbol(.diamond)
                    .symbolSize(40)
            }

        case .heartRate:
            RuleMark(y: .value("Resting guide low", 60))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Resting guide high", 100))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(chartPoints) { point in
                LineMark(x: .value("Date", point.date), y: .value("Daily average heart rate", point.value))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Date", point.date), y: .value("Daily average heart rate", point.value))
                    .foregroundStyle(.red)
                    .symbol(.circle)
                    .symbolSize(34)
            }

        case .sleep:
            RectangleMark(
                xStart: nil,
                xEnd: nil,
                yStart: .value("Sleep guide low", 7),
                yEnd: .value("Sleep guide high", 9)
            )
            .foregroundStyle(.indigo.opacity(0.12))
            ForEach(chartPoints) { point in
                BarMark(x: .value("Date", point.date), y: .value("Sleep duration", point.value), width: .ratio(0.68))
                    .foregroundStyle(.indigo.gradient)
                    .cornerRadius(5)
            }

        case .steps:
            ForEach(chartPoints) { point in
                BarMark(x: .value("Date", point.date), y: .value("Daily steps", point.value), width: .ratio(0.7))
                    .foregroundStyle(.green.opacity(0.65))
                    .cornerRadius(5)
            }
            ForEach(rollingStepPoints) { point in
                LineMark(x: .value("Date", point.date), y: .value("7-day rolling trend", point.value))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

        default:
            ForEach(chartPoints) { point in
                PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
            }
        }
    }

    private var glucoseSegments: [GlucoseSegment] {
        var segments: [[TimeValuePoint]] = []
        for point in chartPoints {
            if let previous = segments.last?.last,
               point.date.timeIntervalSince(previous.date) > 36 * 60 * 60 {
                segments.append([point])
            } else if segments.isEmpty {
                segments.append([point])
            } else {
                segments[segments.count - 1].append(point)
            }
        }
        return segments.enumerated().map { GlucoseSegment(id: $0.offset, points: $0.element) }
    }

    private var rollingStepPoints: [TimeValuePoint] {
        guard metric == .steps, chartPoints.count >= 3 else { return [] }
        return chartPoints.indices.map { index in
            let start = max(chartPoints.startIndex, index - 6)
            let window = chartPoints[start...index]
            let average = window.map(\.value).reduce(0, +) / Double(window.count)
            return TimeValuePoint(date: chartPoints[index].date, value: average)
        }
    }
}

struct ActivityCard: View {
    let points: [ActivityPoint]
    var period = "Selected period"
    var chartHeight: CGFloat = 170

    private var rankedPoints: [ActivityPoint] {
        Array(points.sorted { $0.minutes > $1.minutes }.prefix(8))
    }

    var body: some View {
        MetricCardShell(
            title: "Activities",
            subtitle: "Ranked by total duration",
            systemImage: "figure.run",
            tint: .teal,
            summaries: summaries,
            period: period,
            guides: [MetricGuide(label: "Longest bar: most minutes", symbol: "chart.bar.fill")],
            isEmpty: points.isEmpty,
            insufficientMessage: points.count == 1 ? "One activity type recorded in this period." : nil,
            chartHeight: chartHeight,
            accessibilitySummary: activityAccessibility
        ) {
            Chart(rankedPoints) { point in
                BarMark(
                    x: .value("Minutes", point.minutes),
                    y: .value("Activity", point.name)
                )
                .foregroundStyle(.teal.gradient)
                .cornerRadius(8)
                .annotation(position: .trailing) {
                    Text("\(point.minutes.whole)m")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Rank \((rankedPoints.firstIndex(of: point) ?? 0) + 1), \(point.name)")
                .accessibilityValue("\(point.minutes.whole) minutes")
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let name = value.as(String.self),
                           let rank = rankedPoints.firstIndex(where: { $0.name == name }) {
                            Text("\(rank + 1). \(name)")
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var summaries: [MetricSummary] {
        guard let top = rankedPoints.first else { return [] }
        let total = points.map(\.minutes).reduce(0, +)
        return [
            MetricSummary(label: "Top activity", value: top.name),
            MetricSummary(label: "Period total", value: "\(total.whole) min")
        ]
    }

    private var activityAccessibility: String {
        guard let top = rankedPoints.first else { return "No activities recorded." }
        return "\(points.count) activity types. Top activity \(top.name), \(top.minutes.whole) minutes. Period total \(points.map(\.minutes).reduce(0, +).whole) minutes."
    }
}

struct SelectionCallout: View {
    let date: Date
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.month(.abbreviated).day())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

private struct GlucoseSegment: Identifiable {
    let id: Int
    let points: [TimeValuePoint]
}

@AxisContentBuilder
private var compactDateAxis: some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
    }
}

private func nearestPoint<Point>(
    to selectedDate: Date?,
    in points: [Point],
    date: KeyPath<Point, Date>
) -> Point? {
    guard let selectedDate else { return nil }
    return points.min {
        abs($0[keyPath: date].timeIntervalSince(selectedDate)) <
            abs($1[keyPath: date].timeIntervalSince(selectedDate))
    }
}

extension MetricType {
    var cardTitle: String {
        switch self {
        case .sleep: return "Sleep"
        default: return title
        }
    }

    var cardSubtitle: String {
        switch self {
        case .bloodGlucose: return "Daily average - gaps are not connected"
        case .spo2: return "Daily average - explicit percent scale"
        case .heartRate: return "Current data shown as a daily average"
        case .sleep: return "Daily sleep duration"
        case .steps: return "Daily total - dark line is rolling trend"
        default: return "Daily values"
        }
    }

    func entryUnit(for measurementSystem: MeasurementSystemPreference) -> String {
        switch self {
        case .bloodGlucose: return measurementSystem.glucoseUnit
        case .spo2: return "%"
        case .heartRate: return "bpm"
        case .sleep: return "hours"
        case .steps: return "steps"
        default: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .bloodPressure: return "heart.text.square.fill"
        case .bloodGlucose: return "drop.fill"
        case .spo2: return "lungs.fill"
        case .heartRate: return "waveform.path.ecg"
        case .sleep: return "moon.zzz.fill"
        case .steps: return "shoeprints.fill"
        case .activities: return "figure.run"
        }
    }

    var tint: Color {
        switch self {
        case .bloodPressure, .heartRate: return .red
        case .bloodGlucose: return .pink
        case .spo2: return .cyan
        case .sleep: return .indigo
        case .steps: return .green
        case .activities: return .teal
        }
    }

    var latestLabel: String {
        switch self {
        case .sleep: return "Latest duration"
        case .steps: return "Latest daily total"
        default: return "Latest daily average"
        }
    }

    var averageLabel: String {
        switch self {
        case .steps: return "Average per day"
        default: return "Period average"
        }
    }

    func guides(for measurementSystem: MeasurementSystemPreference) -> [MetricGuide] {
        switch self {
        case .bloodGlucose:
            if measurementSystem == .metric {
                return [MetricGuide(label: "Educational guide: 3.9-10.0 mmol/L", symbol: "rectangle.dashed")]
            }
            return [MetricGuide(label: "Educational guide: 70-180 mg/dL", symbol: "rectangle.dashed")]
        case .spo2:
            return [
                MetricGuide(label: "Dashed guide: 95%", symbol: "line.diagonal"),
                MetricGuide(label: "Dotted guide: 90%", symbol: "ellipsis")
            ]
        case .heartRate:
            return [MetricGuide(label: "General resting guide: 60-100 bpm", symbol: "line.diagonal")]
        case .sleep:
            return [MetricGuide(label: "Educational duration guide: 7-9 hours", symbol: "rectangle.fill")]
        case .steps:
            return [MetricGuide(label: "Dark line: up to 7-day rolling average", symbol: "chart.xyaxis.line")]
        default:
            return []
        }
    }

    func formatted(_ canonicalValue: Double, measurementSystem: MeasurementSystemPreference) -> String {
        let value = self == .bloodGlucose
            ? measurementSystem.displayGlucose(fromMilligramsPerDeciliter: canonicalValue)
            : canonicalValue
        return formattedDisplayValue(value, measurementSystem: measurementSystem)
    }

    func formattedDisplayValue(_ value: Double, measurementSystem: MeasurementSystemPreference) -> String {
        switch self {
        case .bloodGlucose:
            let precision = measurementSystem == .metric ? 1 : 0
            return "\(value.formatted(.number.precision(.fractionLength(precision)))) \(measurementSystem.glucoseUnit)"
        case .spo2: return "\(value.formatted(.number.precision(.fractionLength(1))))%"
        case .heartRate: return "\(value.whole) bpm"
        case .sleep: return "\(value.formatted(.number.precision(.fractionLength(1)))) hr"
        case .steps: return value.formatted(.number.precision(.fractionLength(0)))
        default: return value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    func spoken(_ canonicalValue: Double, measurementSystem: MeasurementSystemPreference) -> String {
        let value = self == .bloodGlucose
            ? measurementSystem.displayGlucose(fromMilligramsPerDeciliter: canonicalValue)
            : canonicalValue
        switch self {
        case .bloodGlucose:
            if measurementSystem == .metric {
                return "\(value.formatted(.number.precision(.fractionLength(1)))) millimoles per liter"
            }
            return "\(value.whole) milligrams per deciliter"
        case .spo2: return "\(value.formatted(.number.precision(.fractionLength(1)))) percent"
        case .heartRate: return "\(value.whole) beats per minute"
        case .sleep: return "\(value.formatted(.number.precision(.fractionLength(1)))) hours"
        case .steps: return "\(value.whole) steps"
        default: return formattedDisplayValue(value, measurementSystem: measurementSystem)
        }
    }

    func yDomain(
        for points: [TimeValuePoint],
        measurementSystem: MeasurementSystemPreference
    ) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1

        switch self {
        case .bloodGlucose:
            if measurementSystem == .metric {
                return max(0, min(3.3, minimum - 0.6))...max(10.5, maximum + 0.6)
            }
            return max(0, min(60, minimum - 10))...max(190, maximum + 10)
        case .spo2:
            return max(70, min(88, minimum - 2))...max(100, maximum + 1)
        case .heartRate:
            return max(0, min(50, minimum - 10))...max(110, maximum + 10)
        case .sleep:
            return 0...max(10, maximum + 1)
        case .steps:
            return 0...max(1, maximum * 1.12)
        default:
            let padding = max(1, (maximum - minimum) * 0.1)
            return (minimum - padding)...(maximum + padding)
        }
    }
}

private extension Double {
    var whole: String {
        formatted(.number.precision(.fractionLength(0)))
    }
}
