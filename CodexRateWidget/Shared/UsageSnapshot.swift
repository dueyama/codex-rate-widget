import Foundation

struct RateLimitWindow: Codable, Equatable, Identifiable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    var id: String { "\(windowDurationMins ?? -1)-\(resetsAt ?? -1)" }
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    var durationLabel: String {
        durationLabel(locale: .current)
    }

    func durationLabel(locale: Locale) -> String {
        guard let minutes = windowDurationMins else {
            return AppLocalization.string("Usage limit", locale: locale)
        }
        if minutes == 300 { return AppLocalization.string("5 hours", locale: locale) }
        if minutes == 10_080 { return AppLocalization.string("Weekly", locale: locale) }
        if minutes.isMultiple(of: 1_440) {
            return AppLocalization.format("%d days", locale: locale, minutes / 1_440)
        }
        if minutes.isMultiple(of: 60) {
            return AppLocalization.format("%d hours", locale: locale, minutes / 60)
        }
        return AppLocalization.format("%d minutes", locale: locale, minutes)
    }
}

struct WeeklyPaceAssessment: Equatable, Sendable {
    let assessedAt: Date
    let actualRemainingPercent: Int
    let targetRemainingPercent: Double

    var shortfallPercent: Double {
        max(0, targetRemainingPercent - Double(actualRemainingPercent))
    }

    var isWarning: Bool {
        shortfallPercent >= WeeklyPace.warningMarginPercent
    }

    /// Whole minutes with no additional account use until the linear pace
    /// line falls to the currently observed remaining percentage.
    var warningRecoveryMinutes: Int? {
        guard isWarning else { return nil }
        let exactMinutes = shortfallPercent / 100 * Double(WeeklyPace.durationMinutes)
        return max(1, Int(ceil(exactMinutes)))
    }
}

struct WeeklyPacePoint: Equatable, Identifiable, Sendable {
    let date: Date
    let targetRemainingPercent: Double
    let cycleEnd: Date

    var id: String {
        "\(cycleEnd.timeIntervalSince1970)-\(date.timeIntervalSince1970)"
    }

    var seriesID: String {
        "weekly-pace-\(cycleEnd.timeIntervalSince1970)"
    }
}

enum WeeklyPace {
    static let durationMinutes = 10_080
    static let duration: TimeInterval = TimeInterval(durationMinutes * 60)
    static let warningMarginPercent = 10.0

    static func assessment(
        for window: RateLimitWindow?,
        at date: Date = .now
    ) -> WeeklyPaceAssessment? {
        guard
            let window,
            window.windowDurationMins == durationMinutes,
            let targetRemainingPercent = targetRemainingPercent(for: window, at: date)
        else { return nil }

        return WeeklyPaceAssessment(
            assessedAt: date,
            actualRemainingPercent: window.remainingPercent,
            targetRemainingPercent: targetRemainingPercent
        )
    }

    static func guidePoints(
        for window: RateLimitWindow?,
        from visibleStart: Date,
        through visibleEnd: Date
    ) -> [WeeklyPacePoint] {
        guard
            let window,
            window.windowDurationMins == durationMinutes,
            let resetDate = window.resetDate,
            visibleStart < visibleEnd,
            targetRemainingPercent(for: window, at: visibleEnd) != nil
        else { return [] }

        // The API exposes only the current reset timestamp. Repeat that
        // seven-day cadence backward so a historical chart can compare prior
        // observations with the pace that applied in each visible cycle.
        let firstCycleOffset = floor(visibleStart.timeIntervalSince(resetDate) / duration) + 1
        var cycleEnd = resetDate.addingTimeInterval(firstCycleOffset * duration)
        var points: [WeeklyPacePoint] = []

        while cycleEnd.addingTimeInterval(-duration) < visibleEnd {
            let cycleStart = cycleEnd.addingTimeInterval(-duration)
            let start = max(visibleStart, cycleStart)
            let end = min(visibleEnd, cycleEnd)

            if start < end {
                points.append(WeeklyPacePoint(
                    date: start,
                    targetRemainingPercent: targetRemainingPercent(
                        inCycleEndingAt: cycleEnd,
                        at: start
                    ),
                    cycleEnd: cycleEnd
                ))
                points.append(WeeklyPacePoint(
                    date: end,
                    targetRemainingPercent: targetRemainingPercent(
                        inCycleEndingAt: cycleEnd,
                        at: end
                    ),
                    cycleEnd: cycleEnd
                ))
            }

            cycleEnd = cycleEnd.addingTimeInterval(duration)
        }

        return points
    }

    private static func targetRemainingPercent(
        for window: RateLimitWindow,
        at date: Date
    ) -> Double? {
        guard let resetDate = window.resetDate else { return nil }
        let cycleStart = resetDate.addingTimeInterval(-duration)
        guard date >= cycleStart, date <= resetDate else { return nil }

        return resetDate.timeIntervalSince(date) / duration * 100
    }

    private static func targetRemainingPercent(
        inCycleEndingAt cycleEnd: Date,
        at date: Date
    ) -> Double {
        cycleEnd.timeIntervalSince(date) / duration * 100
    }
}

enum WeeklyPaceRecoveryFormatting {
    static func duration(minutes: Int, locale: Locale = .current) -> String {
        let totalMinutes = max(0, minutes)
        let days = totalMinutes / 1_440
        let hours = totalMinutes % 1_440 / 60
        let remainingMinutes = totalMinutes % 60

        if days > 0 {
            return AppLocalization.format(
                "%dd %dh %dm",
                locale: locale,
                days,
                hours,
                remainingMinutes
            )
        }
        if hours > 0 {
            return AppLocalization.format(
                "%dh %dm",
                locale: locale,
                hours,
                remainingMinutes
            )
        }
        return AppLocalization.format("%dm", locale: locale, remainingMinutes)
    }
}

enum ResetScheduleFormatting {
    static func dateTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return formatter.string(from: date)
    }

    static func remainingDuration(
        until resetDate: Date,
        now: Date = .now,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String? {
        let interval = resetDate.timeIntervalSince(now)
        guard interval > 0 else { return nil }

        // Round up so an imminent reset never reads as zero minutes remaining.
        let roundedInterval = ceil(interval / 60) * 60
        let formatter = DateComponentsFormatter()
        var localizedCalendar = calendar
        localizedCalendar.locale = locale
        formatter.calendar = localizedCalendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll

        if roundedInterval >= 86_400 {
            formatter.allowedUnits = [.day, .hour]
        } else if roundedInterval >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
        } else {
            formatter.allowedUnits = [.minute]
        }

        return formatter.string(from: roundedInterval)
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let fiveHour: RateLimitWindow?
    let weekly: RateLimitWindow?
    let otherWindows: [RateLimitWindow]
    let planType: String?
    let dailyTokenUsage: [DailyTokenUsage]
    let lifetimeTokens: Int64?
    let updatedAt: Date

    static let empty = UsageSnapshot(
        fiveHour: nil,
        weekly: nil,
        otherWindows: [],
        planType: nil,
        dailyTokenUsage: [],
        lifetimeTokens: nil,
        updatedAt: .distantPast
    )

    static func make(
        windows: [RateLimitWindow],
        planType: String?,
        dailyTokenUsage: [DailyTokenUsage] = [],
        lifetimeTokens: Int64? = nil,
        updatedAt: Date = .now
    ) -> UsageSnapshot {
        let fiveHour = windows.first { $0.windowDurationMins == 300 }
        let weekly = windows.first { $0.windowDurationMins == 10_080 }
        let selectedIDs = Set([fiveHour?.id, weekly?.id].compactMap { $0 })
        return UsageSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            otherWindows: windows.filter { !selectedIDs.contains($0.id) },
            planType: planType,
            dailyTokenUsage: dailyTokenUsage,
            lifetimeTokens: lifetimeTokens,
            updatedAt: updatedAt
        )
    }
}

struct DailyTokenUsage: Codable, Equatable, Identifiable, Sendable {
    let startDate: String
    let tokens: Int64
    var id: String { startDate }
}

enum DailyUsageHistory {
    static func last(
        _ dayCount: Int,
        from usage: [DailyTokenUsage],
        through now: Date = .now,
        calendar: Calendar = .current
    ) -> [DailyTokenUsage] {
        guard dayCount > 0 else { return [] }

        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: 1 - dayCount, to: today) else {
            return []
        }

        return usage.filter { item in
            guard let date = date(from: item.startDate, timeZone: calendar.timeZone) else {
                return false
            }
            let day = calendar.startOfDay(for: date)
            return day >= firstDay && day <= today
        }
        .sorted { $0.startDate < $1.startDate }
    }

    static func date(from startDate: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false

        guard let date = formatter.date(from: startDate), formatter.string(from: date) == startDate else {
            return nil
        }
        return date
    }
}

enum WidgetConstants {
    // TeamIdentifierPrefix is expanded from the signing team at build time
    // and written into both the app and widget extension Info.plist files.
    static var appGroup: String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "CodexRateWidgetAppGroup") as? String,
            !value.isEmpty,
            !value.contains("$("),
            value != Bundle.main.bundleIdentifier
        else { return nil }
        return value
    }
    static let snapshotFileName = "usage-snapshot-v1.json"
    static let remainingHistoryFileName = "remaining-usage-history-v1.json"
    static let snapshotKey = "usage-snapshot-v1"
    static let lastErrorKey = "last-error-v1"
    static let widgetKind = "CodexRateWidget"
}

enum SharedUsageStore {
    static var defaults: UserDefaults? {
        guard let appGroup = WidgetConstants.appGroup else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    static var snapshotURL: URL? {
        guard let appGroup = WidgetConstants.appGroup else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(WidgetConstants.snapshotFileName, isDirectory: false)
    }

    static func load() -> UsageSnapshot {
        if
            let snapshotURL,
            let data = try? Data(contentsOf: snapshotURL),
            let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        {
            return snapshot
        }

        // Keep the preferences fallback so an already-installed older widget
        // can still read snapshots while macOS replaces its cached extension.
        guard
            let data = defaults?.data(forKey: WidgetConstants.snapshotKey),
            let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let snapshotURL, let defaults else { throw StoreError.appGroupUnavailable }
        try data.write(to: snapshotURL, options: .atomic)

        // Mirror to UserDefaults for compatibility with an older cached widget.
        defaults.set(data, forKey: WidgetConstants.snapshotKey)
        defaults.removeObject(forKey: WidgetConstants.lastErrorKey)
        defaults.synchronize()
    }

    static func save(error: Error) {
        defaults?.set(error.localizedDescription, forKey: WidgetConstants.lastErrorKey)
    }

    static var lastError: String? {
        defaults?.string(forKey: WidgetConstants.lastErrorKey)
    }

    enum StoreError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            let locale = DisplayLanguagePreferences.load().locale
            guard let appGroup = WidgetConstants.appGroup else {
                return AppLocalization.string(
                    "App Group is not configured. Select an Apple Development Team in Xcode.",
                    locale: locale
                )
            }
            return AppLocalization.format(
                "Could not open App Group %@. Check Signing & Capabilities.",
                locale: locale,
                appGroup
            )
        }
    }
}
