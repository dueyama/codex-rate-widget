import Foundation

struct RateLimitWindow: Codable, Equatable, Identifiable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?

    var id: String { "\(windowDurationMins ?? -1)-\(resetsAt ?? -1)" }
    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    var durationLabel: String {
        guard let minutes = windowDurationMins else { return String(localized: "Usage limit") }
        if minutes == 300 { return String(localized: "5 hours") }
        if minutes == 10_080 { return String(localized: "Weekly") }
        if minutes.isMultiple(of: 1_440) {
            return String(format: String(localized: "%d days"), minutes / 1_440)
        }
        if minutes.isMultiple(of: 60) {
            return String(format: String(localized: "%d hours"), minutes / 60)
        }
        return String(format: String(localized: "%d minutes"), minutes)
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let fiveHour: RateLimitWindow?
    let weekly: RateLimitWindow?
    let otherWindows: [RateLimitWindow]
    let planType: String?
    let dailyTokenUsage: [DailyTokenUsage]
    let lifetimeTokens: Int64?
    let projectUsage: [ProjectTokenUsage]
    let updatedAt: Date

    static let empty = UsageSnapshot(
        fiveHour: nil,
        weekly: nil,
        otherWindows: [],
        planType: nil,
        dailyTokenUsage: [],
        lifetimeTokens: nil,
        projectUsage: [],
        updatedAt: .distantPast
    )

    static func make(
        windows: [RateLimitWindow],
        planType: String?,
        dailyTokenUsage: [DailyTokenUsage] = [],
        lifetimeTokens: Int64? = nil,
        projectUsage: [ProjectTokenUsage] = [],
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
            projectUsage: projectUsage,
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

struct ProjectTokenUsage: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let tokens: Int64

    var id: String { path }
    var name: String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
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
            guard let appGroup = WidgetConstants.appGroup else {
                return String(localized: "App Group is not configured. Select an Apple Development Team in Xcode.")
            }
            return String(format: String(localized: "Could not open App Group %@. Check Signing & Capabilities."), appGroup)
        }
    }
}
