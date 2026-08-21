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
    let displayLanguage: DisplayLanguage
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
            updatedAt: now
        )
        return UsageEntry(
            date: now,
            snapshot: snapshot,
            remainingHistory: placeholderRemainingHistory(through: now),
            chartMode: .officialTokens,
            historyRange: .oneDay,
            displayLanguage: .system
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
            historyRange: WidgetDisplayPreferences.historyRange(),
            displayLanguage: DisplayLanguagePreferences.load()
        )
    }
}

struct CodexUsageWidget: Widget {
    var body: some WidgetConfiguration {
        let configurationLocale = DisplayLanguagePreferences.load().locale

        return StaticConfiguration(kind: WidgetConstants.widgetKind, provider: UsageProvider()) { entry in
            CodexWidgetView(entry: entry)
                .environment(\.locale, entry.displayLanguage.locale)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
                .widgetURL(URL(string: "codexratewidget://refresh"))
        }
        .configurationDisplayName(Text(verbatim: AppLocalization.string(
            "Codex Remaining Capacity",
            locale: configurationLocale
        )))
        .description(Text(verbatim: AppLocalization.string(
            "Shows active Codex usage limits, token totals, and remaining-capacity history.",
            locale: configurationLocale
        )))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct CodexWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(entry: entry)
        case .systemLarge: LargeUsageView(entry: entry)
        default: MediumUsageView(entry: entry)
        }
    }
}

private struct SmallUsageView: View {
    @Environment(\.locale) private var locale
    let entry: UsageEntry

    private var snapshot: UsageSnapshot { entry.snapshot }
    private var weeklyPaceAssessment: WeeklyPaceAssessment? {
        WeeklyPace.assessment(for: snapshot.weekly, at: snapshot.updatedAt)
    }
    private var paceWarning: Bool {
        weeklyPaceAssessment?.isWarning == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AppLocalizedText("Codex").font(.headline)
                Spacer()
                if paceWarning {
                    WeeklyPaceWarningLamp(showLabel: false)
                } else {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(.secondary)
                }
            }
            if let fiveHour = snapshot.fiveHour {
                LimitRing(
                    title: AppLocalization.string("5 hours", locale: locale),
                    window: fiveHour,
                    size: 88,
                    paceAssessment: nil
                )
                    .frame(maxWidth: .infinity)
            } else if let weekly = snapshot.weekly {
                LimitRing(
                    title: AppLocalization.string("Weekly", locale: locale),
                    window: weekly,
                    size: 88,
                    paceAssessment: weeklyPaceAssessment
                )
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
                AppLocalizedText("No active limit")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WidgetVersionLabel()
                Spacer(minLength: 4)
                Text(updateLabel(snapshot.updatedAt, locale: locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct MediumUsageView: View {
    @Environment(\.locale) private var locale
    let entry: UsageEntry

    private var snapshot: UsageSnapshot { entry.snapshot }
    private var weeklyPaceAssessment: WeeklyPaceAssessment? {
        WeeklyPace.assessment(for: snapshot.weekly, at: snapshot.updatedAt)
    }
    private var paceWarning: Bool {
        weeklyPaceAssessment?.isWarning == true
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                AppLocalizedText("Codex Remaining Capacity").font(.headline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(updateLabel(snapshot.updatedAt, locale: locale))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WidgetVersionLabel()
                }
                Spacer()
                WeeklyResetDetails(window: snapshot.weekly)
                if paceWarning {
                    WeeklyPaceWarningLamp(showLabel: true)
                }
            }
            Spacer()
            LimitRing(
                title: AppLocalization.string("5 hours", locale: locale),
                window: snapshot.fiveHour,
                size: 92,
                paceAssessment: nil
            )
            LimitRing(
                title: AppLocalization.string("Weekly", locale: locale),
                window: snapshot.weekly,
                size: 92,
                paceAssessment: weeklyPaceAssessment
            )
        }
    }
}

private struct LargeUsageView: View {
    @Environment(\.locale) private var locale
    let entry: UsageEntry

    private var snapshot: UsageSnapshot { entry.snapshot }
    private var weeklyPaceAssessment: WeeklyPaceAssessment? {
        WeeklyPace.assessment(for: snapshot.weekly, at: snapshot.updatedAt)
    }
    private var paceWarning: Bool {
        weeklyPaceAssessment?.isWarning == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    AppLocalizedText("Codex Usage").font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(updateLabel(snapshot.updatedAt, locale: locale))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        WidgetVersionLabel()
                    }
                    WeeklyResetDetails(window: snapshot.weekly)
                    if paceWarning {
                        WeeklyPaceWarningLamp(showLabel: true)
                    }
                }
                Spacer()
                LimitRing(
                    title: AppLocalization.string("5 hours", locale: locale),
                    window: snapshot.fiveHour,
                    size: 76,
                    paceAssessment: nil
                )
                LimitRing(
                    title: AppLocalization.string("Weekly", locale: locale),
                    window: snapshot.weekly,
                    size: 76,
                    paceAssessment: weeklyPaceAssessment
                )
            }

            Divider()

            UsageHistorySection(entry: entry, recentDailyUsage: recentDailyUsage)
                .frame(maxHeight: .infinity)
        }
    }

    private var recentDailyUsage: [DailyTokenUsage] {
        DailyUsageHistory.last(7, from: snapshot.dailyTokenUsage)
    }

}

private struct UsageHistorySection: View {
    @Environment(\.locale) private var locale
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
                        Text(AppLocalization.format(
                            "Lifetime %@",
                            locale: locale,
                            tokenCountLabel(lifetimeTokens, locale: locale)
                        ))
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
            AppLocalizedText("Daily · Last 7 Days").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if !recentDailyUsage.isEmpty {
                Text(AppLocalization.format(
                    "Last 7 days %@",
                    locale: locale,
                    tokenCountLabel(
                        recentDailyUsage.reduce(0) { $0 + $1.tokens },
                        locale: locale
                    )
                ))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if recentDailyUsage.isEmpty {
            AppLocalizedText("Daily account data is currently unavailable")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 150)
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
        let guidePoints = WeeklyPace.guidePoints(
            for: entry.snapshot.weekly,
            from: entry.date.addingTimeInterval(-entry.historyRange.duration),
            through: entry.date
        )
        let assessment = WeeklyPace.assessment(
            for: entry.snapshot.weekly,
            at: entry.snapshot.updatedAt
        )

        HStack(spacing: 8) {
            AppLocalizedText("Account Remaining · Saved on This Mac")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            RemainingHistoryLegend(
                points: points,
                showsWeeklyPace: !guidePoints.isEmpty
            )
        }
        if points.isEmpty && guidePoints.isEmpty {
            AppLocalizedText("History begins after the app's next refresh")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 150)
        } else {
            RemainingCapacityChart(
                points: points,
                guidePoints: guidePoints,
                weeklyAssessment: assessment,
                range: entry.historyRange,
                through: entry.date
            )
        }
    }
}

private struct WidgetOptionButton<Intent: AppIntent>: View {
    let title: String
    let selected: Bool
    let intent: Intent

    var body: some View {
        Button(intent: intent) {
            AppLocalizedText(title)
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
    @Environment(\.locale) private var locale
    let points: [RemainingUsageChartPoint]
    let showsWeeklyPace: Bool

    var body: some View {
        HStack(spacing: 7) {
            ForEach(availableKinds, id: \.self) { kind in
                HStack(spacing: 3) {
                    Circle()
                        .fill(remainingHistoryColor(kind))
                        .frame(width: 5, height: 5)
                    Text(remainingHistoryTitle(kind, locale: locale))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            if showsWeeklyPace {
                HStack(spacing: 3) {
                    DottedPaceLine()
                        .stroke(Color.gray.opacity(0.82), style: StrokeStyle(lineWidth: 1.3, dash: [2, 3]))
                        .frame(width: 12, height: 4)
                    AppLocalizedText("7-day pace")
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
    @Environment(\.locale) private var locale
    let points: [RemainingUsageChartPoint]
    let guidePoints: [WeeklyPacePoint]
    let weeklyAssessment: WeeklyPaceAssessment?
    let range: RemainingHistoryRange
    let through: Date

    var body: some View {
        VStack(spacing: 6) {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value(AppLocalization.string("Time", locale: locale), point.capturedAt),
                        y: .value(AppLocalization.string("Remaining %", locale: locale), point.remainingPercent),
                        series: .value(AppLocalization.string("Series", locale: locale), point.seriesID)
                    )
                    .foregroundStyle(remainingHistoryColor(point.kind))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    if points.count <= 12 {
                        PointMark(
                            x: .value(AppLocalization.string("Time", locale: locale), point.capturedAt),
                            y: .value(AppLocalization.string("Remaining %", locale: locale), point.remainingPercent)
                        )
                        .foregroundStyle(remainingHistoryColor(point.kind))
                        .symbolSize(10)
                    }
                }

                ForEach(guidePoints) { point in
                    LineMark(
                        x: .value(AppLocalization.string("Time", locale: locale), point.date),
                        y: .value(
                            AppLocalization.string("7-day pace", locale: locale),
                            point.targetRemainingPercent
                        ),
                        series: .value(
                            AppLocalization.string("Series", locale: locale),
                            point.seriesID
                        )
                    )
                    .foregroundStyle(Color.gray.opacity(0.82))
                    .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [2, 3]))
                }

                if let weeklyAssessment {
                    PointMark(
                        x: .value(
                            AppLocalization.string("Time", locale: locale),
                            weeklyAssessment.assessedAt
                        ),
                        y: .value(
                            AppLocalization.string("Remaining %", locale: locale),
                            weeklyAssessment.actualRemainingPercent
                        )
                    )
                    .foregroundStyle(weeklyAssessment.isWarning ? Color.red : Color.green)
                    .symbolSize(20)
                }
            }
            .chartXScale(domain: startDate...through)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.primary.opacity(0.28))
                    AxisValueLabel {
                        if let percent = value.as(Int.self) {
                            Text("\(percent)%")
                                .font(.system(size: 7, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.primary.opacity(0.65))
                        }
                    }
                }
            }
            .frame(height: 133)

            HStack {
                Text(verbatim: remainingHistoryAxisLabel(startDate, range: range, locale: locale))
                Spacer()
                Text(verbatim: remainingHistoryAxisLabel(through, range: range, locale: locale))
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.leading, 28)
        }
        .frame(height: 150)
    }

    private var startDate: Date {
        through.addingTimeInterval(-range.duration)
    }
}

private struct DailyTokenChart: View {
    @Environment(\.locale) private var locale
    let usage: [DailyTokenUsage]

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(usage) { item in
                    Text(verbatim: tokenCountLabel(item.tokens, locale: locale))
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
                    x: .value(AppLocalization.string("Day", locale: locale), item.startDate),
                    y: .value(AppLocalization.string("Tokens", locale: locale), item.tokens)
                )
                .foregroundStyle(.blue)
                .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 124)

            HStack(spacing: 0) {
                ForEach(usage) { item in
                    Text(verbatim: dailyDateLabel(item.startDate, locale: locale))
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
        .frame(height: 150)
    }
}

private struct WeeklyResetDetails: View {
    @Environment(\.locale) private var locale
    let window: RateLimitWindow?

    var body: some View {
        if let window {
            if let resetDate = window.resetDate {
                if let remaining = ResetScheduleFormatting.remainingDuration(
                    until: resetDate,
                    locale: locale
                ) {
                    VStack(alignment: .leading, spacing: 1) {
                        AppLocalizedText("Weekly reset")
                            .font(.caption2.weight(.semibold))
                        Text(verbatim: ResetScheduleFormatting.dateTime(resetDate, locale: locale))
                            .font(.caption2.monospacedDigit())
                        Text(AppLocalization.format("%@ remaining", locale: locale, remaining))
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

    private func resetStateText(_ text: String) -> some View {
        AppLocalizedText(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private struct LimitRing: View {
    @Environment(\.locale) private var locale
    let title: String
    let window: RateLimitWindow?
    let size: CGFloat
    let paceAssessment: WeeklyPaceAssessment?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.15), lineWidth: max(6, size * 0.08))
                if let window {
                    if
                        let paceAssessment,
                        paceAssessment.targetRemainingPercent > Double(window.remainingPercent)
                    {
                        Circle()
                            .trim(
                                from: 0,
                                to: CGFloat(min(100, max(0, paceAssessment.targetRemainingPercent))) / 100
                            )
                            .stroke(
                                Color.blue.opacity(0.38),
                                style: StrokeStyle(lineWidth: max(6, size * 0.08), lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .accessibilityHidden(true)
                    }
                    Circle()
                        .trim(from: 0, to: CGFloat(window.remainingPercent) / 100)
                        .stroke(color(window.remainingPercent), style: StrokeStyle(lineWidth: max(6, size * 0.08), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: -2) {
                        Text("\(window.remainingPercent)%")
                            .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                        Text(verbatim: AppLocalization.string("Remaining", locale: locale))
                            .font(.system(size: size * 0.105))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 1) {
                        Image(systemName: "minus").font(.headline)
                        Text(verbatim: AppLocalization.string("Unavailable", locale: locale))
                            .font(.system(size: size * 0.1))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if paceWarning {
                    WeeklyPaceWarningLamp(showLabel: false)
                        .background(.background, in: Circle())
                }
            }
            Text(title).font(.caption2.weight(.semibold))
        }
    }

    private var paceWarning: Bool {
        paceAssessment?.isWarning == true
    }

    private func color(_ remaining: Int) -> Color {
        if paceWarning { return .red }
        if remaining <= 20 { return .red }
        if remaining <= 40 { return .orange }
        return .green
    }
}

private struct WeeklyPaceWarningLamp: View {
    @Environment(\.locale) private var locale
    let showLabel: Bool

    @ViewBuilder
    var body: some View {
        if showLabel {
            Label {
                AppLocalizedText("Weekly pace warning")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(Text(verbatim: AppLocalization.string(
                    "Weekly pace warning",
                    locale: locale
                )))
        }
    }
}

private struct DottedPaceLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct WidgetVersionLabel: View {
    @Environment(\.locale) private var locale

    var body: some View {
        if let version = BuildVersionInfo.current {
            Text(verbatim: version.compactLabel)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel(Text(verbatim: version.accessibilityLabel(locale: locale)))
        }
    }
}

private func updateLabel(_ date: Date, locale: Locale) -> String {
    guard date != .distantPast else {
        return AppLocalization.string("Launch the app to fetch usage", locale: locale)
    }
    return AppLocalization.format(
        "Updated %@",
        locale: locale,
        date.formatted(.dateTime.hour().minute().locale(locale))
    )
}

private func dailyDateLabel(_ startDate: String, locale: Locale) -> String {
    guard let date = DailyUsageHistory.date(from: startDate) else { return startDate }
    return date.formatted(
        .dateTime.month(.defaultDigits).day(.defaultDigits).locale(locale)
    )
}

private func tokenCountLabel(_ tokens: Int64, locale: Locale) -> String {
    if locale.language.languageCode?.identifier == "ja", tokens >= 100_000_000 {
        return String(format: "%.1f億", locale: locale, Double(tokens) / 100_000_000)
    }
    if locale.language.languageCode?.identifier == "ja", tokens >= 10_000 {
        return String(format: "%.1f万", locale: locale, Double(tokens) / 10_000)
    }
    return tokens.formatted(.number.notation(.compactName).locale(locale))
}

private func remainingHistoryColor(_ kind: RemainingLimitKind) -> Color {
    switch kind {
    case .fiveHour: .blue
    case .weekly: .green
    }
}

private func remainingHistoryTitle(_ kind: RemainingLimitKind, locale: Locale) -> String {
    switch kind {
    case .fiveHour: AppLocalization.string("5 hours", locale: locale)
    case .weekly: AppLocalization.string("Weekly", locale: locale)
    }
}

private func remainingHistoryAxisLabel(
    _ date: Date,
    range: RemainingHistoryRange,
    locale: Locale
) -> String {
    switch range {
    case .oneDay:
        date.formatted(
            .dateTime.month(.defaultDigits).day(.defaultDigits).hour().minute().locale(locale)
        )
    case .sevenDays:
        date.formatted(
            .dateTime.month(.defaultDigits).day(.defaultDigits).locale(locale)
        )
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
