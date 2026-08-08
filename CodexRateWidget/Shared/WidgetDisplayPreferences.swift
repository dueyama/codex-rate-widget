import AppIntents
import Foundation
import WidgetKit

enum WidgetChartMode: String, Codable, CaseIterable, Sendable {
    case officialTokens
    case remainingHistory
}

extension WidgetChartMode: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Usage chart"
    }

    static var caseDisplayRepresentations: [WidgetChartMode: DisplayRepresentation] {
        [
            .officialTokens: "Daily Usage",
            .remainingHistory: "Remaining History"
        ]
    }
}

extension RemainingHistoryRange: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "History range"
    }

    static var caseDisplayRepresentations: [RemainingHistoryRange: DisplayRepresentation] {
        [
            .oneDay: "24 Hours",
            .sevenDays: "7 Days"
        ]
    }
}

enum WidgetDisplayPreferences {
    private static let chartModeKey = "large-widget-chart-mode-v1"
    private static let historyRangeKey = "large-widget-history-range-v1"

    static func chartMode(defaults: UserDefaults? = SharedUsageStore.defaults) -> WidgetChartMode {
        guard
            let rawValue = defaults?.string(forKey: chartModeKey),
            let mode = WidgetChartMode(rawValue: rawValue)
        else { return .officialTokens }
        return mode
    }

    static func historyRange(defaults: UserDefaults? = SharedUsageStore.defaults) -> RemainingHistoryRange {
        guard
            let rawValue = defaults?.string(forKey: historyRangeKey),
            let range = RemainingHistoryRange(rawValue: rawValue)
        else { return .oneDay }
        return range
    }

    static func save(chartMode: WidgetChartMode, defaults: UserDefaults? = SharedUsageStore.defaults) {
        defaults?.set(chartMode.rawValue, forKey: chartModeKey)
    }

    static func save(historyRange: RemainingHistoryRange, defaults: UserDefaults? = SharedUsageStore.defaults) {
        defaults?.set(historyRange.rawValue, forKey: historyRangeKey)
    }
}

struct SetWidgetChartModeIntent: AppIntent {
    static var title: LocalizedStringResource { "Change usage chart" }
    static var description: IntentDescription {
        IntentDescription("Switches the large widget between daily token usage and locally recorded remaining capacity.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Chart")
    var mode: WidgetChartMode

    init() {
        mode = .officialTokens
    }

    init(mode: WidgetChartMode) {
        self.mode = mode
    }

    func perform() async throws -> some IntentResult {
        WidgetDisplayPreferences.save(chartMode: mode)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.widgetKind)
        return .result()
    }
}

struct SetRemainingHistoryRangeIntent: AppIntent {
    static var title: LocalizedStringResource { "Change remaining history range" }
    static var description: IntentDescription {
        IntentDescription("Switches the remaining-capacity chart between the past 24 hours and the past 7 days.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Range")
    var range: RemainingHistoryRange

    init() {
        range = .oneDay
    }

    init(range: RemainingHistoryRange) {
        self.range = range
    }

    func perform() async throws -> some IntentResult {
        WidgetDisplayPreferences.save(historyRange: range)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.widgetKind)
        return .result()
    }
}
