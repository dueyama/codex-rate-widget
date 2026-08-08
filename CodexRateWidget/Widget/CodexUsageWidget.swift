import AppIntents
import Charts
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let remainingHistory: RemainingUsageHistory
    let chartMode: WidgetChartMode
    let historyRange: RemainingHistoryRange
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        let now = Date.now
        let snapshot = UsageSnapshot.make(
            windows: [
                RateLimitWindow(usedPercent: 34, windowDurationMins: 300, resetsAt: Int(now.addingTimeInterval(6_000).timeIntervalSince1970)),
                RateLimitWindow(usedPercent: 28, windowDurationMins: 10_080, resetsAt: Int(now.addingTimeInterval(400_000).timeIntervalSince1970))
            ],
            planType: "pro",
            dailyTokenUsage: placeholderDailyUsage(through: now),
            lifetimeTokens: 12_345_678,
            projectUsage: [
                .init(path: "/Projects/ExampleApp", tokens: 610_000),
                .init(path: "/Projects/ResearchLab", tokens: 380_000),
                .init(path: "/Projects/Documentation", tokens: 160_000)
            ],
            updatedAt: now
        )
        return UsageEntry(
            date: now,
            snapshot: snapshot,
            remainingHistory: placeholderRemainingHistory(through: now),
            chartMode: .officialTokens,
            historyRange: .oneDay
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry(at date: Date = .now) -> UsageEntry {
        UsageEntry(
            date: date,
            snapshot: SharedUsageStore.load(),
            remainingHistory: SharedRemainingUsageHistoryStore.load(),
            chartMode: WidgetDisplayPreferences.chartMode(),
            historyRange: WidgetDisplayPreferences.historyRange()
        )
    }
}

struct CodexUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetConstants.widgetKind, provider: UsageProvider()) { entry in
            CodexWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
                .widgetURL(URL(string: "codexratewidget://refresh"))
        }
        .configurationDisplayName("Codex Remaining Capacity")
        .description("Shows active Codex usage limits, token totals, remaining-capacity history, and estimated usage by project.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct CodexWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(snapshot: entry.snapshot)
        case .systemLarge: LargeUsageView(entry: entry)
        default: MediumUsageView(snapshot: entry.snapshot)
        }
    }
}

private struct SmallUsageView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex").font(.headline)
                Spacer()
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(.secondary)
            }
            if let fiveHour = snapshot.fiveHour {
                LimitRing(title: String(localized: "5 hours"), window: fiveHour, size: 88)
                    .frame(maxWidth: .infinity)
            } else if let weekly = snapshot.weekly {
                LimitRing(title: String(localized: "Weekly"), window: weekly, size: 88)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
                Text("No active limit")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WidgetVersionLabel()
                Spacer(minLength: 4)
                Text(updateLabel(snapshot.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct MediumUsageView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex Remaining Capacity").font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(updateLabel(snapshot.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WidgetVersionLabel()
                }
                Spacer()
                WeeklyResetDetails(window: snapshot.weekly)
            }
            Spacer()
            LimitRing(title: String(localized: "5 hours"), window: snapshot.fiveHour, size: 92)
            LimitRing(title: String(localized: "Weekly"), window: snapshot.weekly, size: 92)
        }
    }
}

private struct LargeUsageView: View {
    let entry: UsageEntry

    private var snapshot: UsageSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Usage").font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(updateLabel(snapshot.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        WidgetVersionLabel()
                    }
                    WeeklyResetDetails(window: snapshot.weekly)
                }
                Spacer()
                LimitRing(title: String(localized: "5 hours"), window: snapshot.fiveHour, size: 76)
                LimitRing(title: String(localized: "Weekly"), window: snapshot.weekly, size: 76)
            }

            Divider()

            UsageHistorySection(entry: entry, recentDailyUsage: recentDailyUsage)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("By Project · Last 7 Days").font(.caption.weight(.semibold))
                    Spacer()
                    Text("Local Estimate · Unofficial").font(.caption2).foregroundStyle(.orange)
                }
                if recentOfficialTokenTotal <= 0 {
                    Text("No official 7-day total is available to estimate")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if snapshot.projectUsage.isEmpty {
                    Text("No local sessions are available to estimate")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.projectUsage.prefix(3)) { project in
                        ProjectRow(project: project, maximum: snapshot.projectUsage.first?.tokens ?? 1)
                    }
                }
            }
        }
    }

    private var recentDailyUsage: [DailyTokenUsage] {
        DailyUsageHistory.last(7, from: snapshot.dailyTokenUsage)
    }

    private var recentOfficialTokenTotal: Int64 {
        recentDailyUsage.reduce(0) { $0 + $1.tokens }
    }
}

private struct UsageHistorySection: View {
    let entry: UsageEntry
    let recentDailyUsage: [DailyTokenUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                WidgetOptionButton(
                    title: "Daily Usage",
                    selected: entry.chartMode == .officialTokens,
                    intent: SetWidgetChartModeIntent(mode: .officialTokens)
                )
                WidgetOptionButton(
                    title: "Remaining History",
                    selected: entry.chartMode == .remainingHistory,
                    intent: SetWidgetChartModeIntent(mode: .remainingHistory)
                )
                Spacer(minLength: 6)
                if entry.chartMode == .officialTokens {
                    if let lifetimeTokens = entry.snapshot.lifetimeTokens {
                        Text(String(format: String(localized: "Lifetime %@"), tokenCountLabel(lifetimeTokens)))
                            .font(.caption2.weight(.semibold))
                    }
                } else {
                    WidgetOptionButton(
                        title: "24h",
                        selected: entry.historyRange == .oneDay,
                        intent: SetRemainingHistoryRangeIntent(range: .oneDay)
                    )
                    WidgetOptionButton(
                        title: "7d",
                        selected: entry.historyRange == .sevenDays,
                        intent: SetRemainingHistoryRangeIntent(range: .sevenDays)
                    )
                }
            }

            if entry.chartMode == .officialTokens {
                officialTokenContent
            } else {
                remainingHistoryContent
            }
        }
    }

    @ViewBuilder
    private var officialTokenContent: some View {
        HStack {
            Text("Daily · Last 7 Days").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if !recentDailyUsage.isEmpty {
                Text(String(
                    format: String(localized: "Last 7 days %@"),
                    tokenCountLabel(recentDailyUsage.reduce(0) { $0 + $1.tokens })
                ))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if recentDailyUsage.isEmpty {
            Text("Daily account data is currently unavailable")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 68)
        } else {
            DailyTokenChart(usage: recentDailyUsage)
        }
    }

    @ViewBuilder
    private var remainingHistoryContent: some View {
        let points = entry.remainingHistory.chartPoints(
            in: entry.historyRange,
            through: entry.date
        )

        HStack(spacing: 8) {
            Text("Recorded on This Mac · Every 15 Minutes")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            RemainingHistoryLegend(points: points)
        }
        if points.isEmpty {
            Text("History begins after the app's next refresh")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 68)
        } else {
            RemainingCapacityChart(
                points: points,
                range: entry.historyRange,
                through: entry.date
            )
        }
    }
}

private struct WidgetOptionButton<Intent: AppIntent>: View {
    let title: LocalizedStringKey
    let selected: Bool
    let intent: Intent

    var body: some View {
        Button(intent: intent) {
            Text(title)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(selected ? Color.blue.opacity(0.16) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct RemainingHistoryLegend: View {
    let points: [RemainingUsageChartPoint]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(availableKinds, id: \.self) { kind in
                HStack(spacing: 3) {
                    Circle()
                        .fill(remainingHistoryColor(kind))
                        .frame(width: 5, height: 5)
                    Text(remainingHistoryTitle(kind))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var availableKinds: [RemainingLimitKind] {
        RemainingLimitKind.allCases.filter { kind in
            points.contains { $0.kind == kind }
        }
    }
}

private struct RemainingCapacityChart: View {
    let points: [RemainingUsageChartPoint]
    let range: RemainingHistoryRange
    let through: Date

    var body: some View {
        VStack(spacing: 1) {
            Chart(points) { point in
                LineMark(
                    x: .value(String(localized: "Time"), point.capturedAt),
                    y: .value(String(localized: "Remaining %"), point.remainingPercent),
                    series: .value(String(localized: "Series"), point.seriesID)
                )
                .foregroundStyle(remainingHistoryColor(point.kind))
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                if points.count <= 12 {
                    PointMark(
                        x: .value(String(localized: "Time"), point.capturedAt),
                        y: .value(String(localized: "Remaining %"), point.remainingPercent)
                    )
                    .foregroundStyle(remainingHistoryColor(point.kind))
                    .symbolSize(10)
                }
            }
            .chartXScale(domain: startDate...through)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.18))
                    AxisValueLabel {
                        if let percent = value.as(Int.self) {
                            Text("\(percent)%")
                                .font(.system(size: 7, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 51)

            HStack {
                Text(verbatim: remainingHistoryAxisLabel(startDate, range: range))
                Spacer()
                Text(verbatim: remainingHistoryAxisLabel(through, range: range))
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(height: 68)
    }

    private var startDate: Date {
        through.addingTimeInterval(-range.duration)
    }
}

private struct DailyTokenChart: View {
    let usage: [DailyTokenUsage]

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(usage) { item in
                    Text(verbatim: tokenCountLabel(item.tokens))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            Chart(usage) { item in
                BarMark(
                    x: .value(String(localized: "Day"), item.startDate),
                    y: .value(String(localized: "Tokens"), item.tokens)
                )
                .foregroundStyle(.blue)
                .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 42)

            HStack(spacing: 0) {
                ForEach(usage) { item in
                    Text(verbatim: dailyDateLabel(item.startDate))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(height: 68)
    }
}

private struct WeeklyResetDetails: View {
    let window: RateLimitWindow?

    var body: some View {
        if let window {
            if let resetDate = window.resetDate {
                if let remaining = ResetScheduleFormatting.remainingDuration(until: resetDate) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Weekly reset")
                            .font(.caption2.weight(.semibold))
                        Text(verbatim: ResetScheduleFormatting.dateTime(resetDate))
                            .font(.caption2.monospacedDigit())
                        Text(String(format: String(localized: "%@ remaining"), remaining))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                } else {
                    resetStateText("Refresh to update the weekly reset")
                }
            } else {
                resetStateText("Weekly reset time unknown")
            }
        }
    }

    private func resetStateText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private struct LimitRing: View {
    let title: String
    let window: RateLimitWindow?
    let size: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: max(6, size * 0.08))
                if let window {
                    Circle()
                        .trim(from: 0, to: CGFloat(window.remainingPercent) / 100)
                        .stroke(color(window.remainingPercent), style: StrokeStyle(lineWidth: max(6, size * 0.08), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -2) {
                        Text("\(window.remainingPercent)%")
                            .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                        Text("Remaining").font(.system(size: size * 0.105)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: "minus").font(.headline)
                        Text("Unavailable").font(.system(size: size * 0.1)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            Text(title).font(.caption2.weight(.semibold))
        }
    }

    private func color(_ remaining: Int) -> Color {
        if remaining <= 20 { return .red }
        if remaining <= 40 { return .orange }
        return .green
    }
}

private struct WidgetVersionLabel: View {
    var body: some View {
        if let version = BuildVersionInfo.current {
            Text(verbatim: version.compactLabel)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel(Text(verbatim: version.accessibilityLabel))
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectTokenUsage
    let maximum: Int64

    var body: some View {
        HStack(spacing: 8) {
            Text(project.name).lineLimit(1).font(.caption2).frame(width: 92, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(.blue.opacity(0.22))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.blue.gradient)
                            .frame(width: geometry.size.width * CGFloat(project.tokens) / CGFloat(max(1, maximum)))
                    }
            }
            .frame(height: 7)
            Text(String(format: String(localized: "Approx. %@"), tokenCountLabel(project.tokens)))
                .font(.caption2.monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
    }
}

private func updateLabel(_ date: Date) -> String {
    guard date != .distantPast else { return String(localized: "Launch the app to fetch usage") }
    return String(
        format: String(localized: "Updated %@"),
        date.formatted(date: .omitted, time: .shortened)
    )
}

private func dailyDateLabel(_ startDate: String) -> String {
    guard let date = DailyUsageHistory.date(from: startDate) else { return startDate }
    return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
}

private func tokenCountLabel(_ tokens: Int64) -> String {
    if Locale.current.language.languageCode?.identifier == "ja", tokens >= 100_000_000 {
        return String(format: "%.1f億", Double(tokens) / 100_000_000)
    }
    if Locale.current.language.languageCode?.identifier == "ja", tokens >= 10_000 {
        return String(format: "%.1f万", Double(tokens) / 10_000)
    }
    return tokens.formatted(.number.notation(.compactName))
}

private func remainingHistoryColor(_ kind: RemainingLimitKind) -> Color {
    switch kind {
    case .fiveHour: .blue
    case .weekly: .green
    }
}

private func remainingHistoryTitle(_ kind: RemainingLimitKind) -> String {
    switch kind {
    case .fiveHour: String(localized: "5 hours")
    case .weekly: String(localized: "Weekly")
    }
}

private func remainingHistoryAxisLabel(_ date: Date, range: RemainingHistoryRange) -> String {
    switch range {
    case .oneDay:
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits).hour().minute())
    case .sevenDays:
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }
}

private func placeholderDailyUsage(through now: Date) -> [DailyTokenUsage] {
    let tokens: [Int64] = [230_000, 410_000, 180_000, 560_000, 320_000, 690_000, 270_000]
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"

    return tokens.enumerated().compactMap { index, tokenCount in
        guard let date = Calendar.current.date(byAdding: .day, value: index - (tokens.count - 1), to: now) else {
            return nil
        }
        return DailyTokenUsage(startDate: formatter.string(from: date), tokens: tokenCount)
    }
}

private func placeholderRemainingHistory(through now: Date) -> RemainingUsageHistory {
    let samples = (0...48).map { index in
        let capturedAt = now.addingTimeInterval(TimeInterval(index - 48) * 3_600)
        let fiveHourRemaining = 92 - ((index * 9) % 78)
        let weeklyRemaining = max(28, 84 - index)
        return RemainingUsageSample(
            capturedAt: capturedAt,
            fiveHourRemainingPercent: fiveHourRemaining,
            weeklyRemainingPercent: weeklyRemaining
        )
    }
    return RemainingUsageHistory(samples: samples)
}
