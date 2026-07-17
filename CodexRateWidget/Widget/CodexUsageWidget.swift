import Charts
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: .make(
            windows: [
                RateLimitWindow(usedPercent: 34, windowDurationMins: 300, resetsAt: Int(Date.now.addingTimeInterval(6_000).timeIntervalSince1970)),
                RateLimitWindow(usedPercent: 28, windowDurationMins: 10_080, resetsAt: Int(Date.now.addingTimeInterval(400_000).timeIntervalSince1970))
            ],
            planType: "pro",
            dailyTokenUsage: [
                .init(startDate: "2026-07-12", tokens: 230_000),
                .init(startDate: "2026-07-13", tokens: 410_000),
                .init(startDate: "2026-07-14", tokens: 180_000),
                .init(startDate: "2026-07-15", tokens: 560_000)
            ],
            lifetimeTokens: 12_345_678,
            projectUsage: [
                .init(path: "/Projects/ExampleApp", tokens: 610_000),
                .init(path: "/Projects/ResearchLab", tokens: 380_000),
                .init(path: "/Projects/Documentation", tokens: 160_000)
            ]
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: context.isPreview ? placeholder(in: context).snapshot : SharedUsageStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: .now, snapshot: SharedUsageStore.load())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
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
        .description("Shows active Codex usage limits, token totals, and estimated usage by project.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct CodexWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallUsageView(snapshot: entry.snapshot)
        case .systemLarge: LargeUsageView(snapshot: entry.snapshot)
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
                StatusText(title: String(localized: "5-hour limit"), active: snapshot.fiveHour != nil)
                StatusText(title: String(localized: "Weekly limit"), active: snapshot.weekly != nil)
            }
            Spacer()
            LimitRing(title: String(localized: "5 hours"), window: snapshot.fiveHour, size: 92)
            LimitRing(title: String(localized: "Weekly"), window: snapshot.weekly, size: 92)
        }
    }
}

private struct LargeUsageView: View {
    let snapshot: UsageSnapshot

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
                }
                Spacer()
                LimitRing(title: String(localized: "5 hours"), window: snapshot.fiveHour, size: 76)
                LimitRing(title: String(localized: "Weekly"), window: snapshot.weekly, size: 76)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Official Tokens").font(.caption.weight(.semibold))
                    Spacer()
                    if let lifetimeTokens = snapshot.lifetimeTokens {
                        Text(String(format: String(localized: "Lifetime %@"), tokenCountLabel(lifetimeTokens)))
                            .font(.caption2.weight(.semibold))
                    }
                }
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
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    Chart(recentDailyUsage) { item in
                        BarMark(
                            x: .value(String(localized: "Day"), item.startDate),
                            y: .value(String(localized: "Tokens"), item.tokens)
                        )
                        .foregroundStyle(.blue.gradient)
                        .cornerRadius(3)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 64)
                }
            }

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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .distantPast
        return snapshot.dailyTokenUsage.filter {
            guard let date = formatter.date(from: $0.startDate) else { return false }
            return date >= Calendar.current.startOfDay(for: cutoff)
        }
    }

    private var recentOfficialTokenTotal: Int64 {
        recentDailyUsage.reduce(0) { $0 + $1.tokens }
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

private struct StatusText: View {
    let title: String
    let active: Bool
    var body: some View {
        Label(
            String(format: active ? String(localized: "%@ Active") : String(localized: "%@ Unavailable"), title),
            systemImage: active ? "checkmark.circle.fill" : "minus.circle"
        )
            .font(.caption2)
            .foregroundStyle(active ? .primary : .secondary)
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

private func tokenCountLabel(_ tokens: Int64) -> String {
    if Locale.current.language.languageCode?.identifier == "ja", tokens >= 100_000_000 {
        return String(format: "%.1f億", Double(tokens) / 100_000_000)
    }
    if Locale.current.language.languageCode?.identifier == "ja", tokens >= 10_000 {
        return String(format: "%.1f万", Double(tokens) / 10_000)
    }
    return tokens.formatted(.number.notation(.compactName))
}
