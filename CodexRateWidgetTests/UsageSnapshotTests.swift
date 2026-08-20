import XCTest
import SQLite3
@testable import CodexRateWidget

final class UsageSnapshotTests: XCTestCase {
    func testMissingFiveHourWindowStaysInactive() {
        let weekly = RateLimitWindow(usedPercent: 28, windowDurationMins: 10_080, resetsAt: 1_800_000_000)
        let snapshot = UsageSnapshot.make(windows: [weekly], planType: "pro")

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 72)
    }

    func testFiveHourWindowReturnsAutomaticallyWhenReported() {
        let short = RateLimitWindow(usedPercent: 61, windowDurationMins: 300, resetsAt: 1_800_000_000)
        let weekly = RateLimitWindow(usedPercent: 28, windowDurationMins: 10_080, resetsAt: 1_800_100_000)
        let snapshot = UsageSnapshot.make(windows: [weekly, short], planType: "pro")

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 39)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 72)
    }

    func testUnknownWindowIsPreservedWithoutMislabelingIt() {
        let daily = RateLimitWindow(usedPercent: 10, windowDurationMins: 1_440, resetsAt: nil)
        let snapshot = UsageSnapshot.make(windows: [daily], planType: nil)

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.otherWindows, [daily])
    }

    func testResetScheduleFormattingShowsDateAndRemainingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 6,
            hour: 9,
            minute: 30
        )))
        let resetDate = now.addingTimeInterval((4 * 86_400) + (5 * 3_600) + (23 * 60))

        XCTAssertEqual(
            ResetScheduleFormatting.remainingDuration(
                until: resetDate,
                now: now,
                locale: locale,
                calendar: calendar
            ),
            "4d 5h"
        )
        XCTAssertEqual(
            ResetScheduleFormatting.dateTime(
                resetDate,
                locale: Locale(identifier: "ja_JP"),
                timeZone: calendar.timeZone
            ),
            "8月10日 14:53"
        )
        XCTAssertNil(ResetScheduleFormatting.remainingDuration(
            until: now,
            now: now,
            locale: locale,
            calendar: calendar
        ))
        XCTAssertEqual(
            ResetScheduleFormatting.remainingDuration(
                until: now.addingTimeInterval(20),
                now: now,
                locale: locale,
                calendar: calendar
            ),
            "1m"
        )
    }

    func testWeeklyPaceUsesAConstantSevenDayTargetAndTenPointWarningMargin() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetDate = now.addingTimeInterval(WeeklyPace.duration / 2)
        let resetTimestamp = Int(resetDate.timeIntervalSince1970)

        let onPace = RateLimitWindow(
            usedPercent: 50,
            windowDurationMins: 10_080,
            resetsAt: resetTimestamp
        )
        let warning = RateLimitWindow(
            usedPercent: 60,
            windowDurationMins: 10_080,
            resetsAt: resetTimestamp
        )

        let onPaceAssessment = try XCTUnwrap(WeeklyPace.assessment(for: onPace, at: now))
        XCTAssertEqual(onPaceAssessment.assessedAt, now)
        XCTAssertEqual(onPaceAssessment.targetRemainingPercent, 50, accuracy: 0.001)
        XCTAssertEqual(onPaceAssessment.shortfallPercent, 0, accuracy: 0.001)
        XCTAssertFalse(onPaceAssessment.isWarning)

        let warningAssessment = try XCTUnwrap(WeeklyPace.assessment(for: warning, at: now))
        XCTAssertEqual(warningAssessment.shortfallPercent, 10, accuracy: 0.001)
        XCTAssertTrue(warningAssessment.isWarning)
    }

    func testWeeklyPaceRejectsMissingOrStaleWeeklyCycles() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fiveHour = RateLimitWindow(
            usedPercent: 50,
            windowDurationMins: 300,
            resetsAt: Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let expiredWeekly = RateLimitWindow(
            usedPercent: 50,
            windowDurationMins: 10_080,
            resetsAt: Int(now.addingTimeInterval(-1).timeIntervalSince1970)
        )

        XCTAssertNil(WeeklyPace.assessment(for: fiveHour, at: now))
        XCTAssertNil(WeeklyPace.assessment(for: expiredWeekly, at: now))
        XCTAssertNil(WeeklyPace.assessment(for: nil, at: now))
    }

    func testWeeklyPaceGuideClipsToTheVisibleChartRange() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetDate = now.addingTimeInterval(2 * 86_400)
        let weekly = RateLimitWindow(
            usedPercent: 35,
            windowDurationMins: 10_080,
            resetsAt: Int(resetDate.timeIntervalSince1970)
        )
        let visibleStart = now.addingTimeInterval(-86_400)

        let points = WeeklyPace.guidePoints(
            for: weekly,
            from: visibleStart,
            through: now
        )

        XCTAssertEqual(points.map(\.date), [visibleStart, now])
        XCTAssertEqual(points[0].targetRemainingPercent, 72.0 / 168.0 * 100, accuracy: 0.001)
        XCTAssertEqual(points[1].targetRemainingPercent, 48.0 / 168.0 * 100, accuracy: 0.001)
    }

    func testWeeklyPaceGuideRepeatsPastCyclesWithoutJoiningAcrossReset() throws {
        let resetDate = Date(timeIntervalSince1970: 2_000_000_000)
        let weekly = RateLimitWindow(
            usedPercent: 20,
            windowDurationMins: 10_080,
            resetsAt: Int(resetDate.timeIntervalSince1970)
        )
        let visibleStart = resetDate.addingTimeInterval(-2 * WeeklyPace.duration)
        let visibleEnd = resetDate.addingTimeInterval(-WeeklyPace.duration / 2)

        let points = WeeklyPace.guidePoints(
            for: weekly,
            from: visibleStart,
            through: visibleEnd
        )

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.map(\.targetRemainingPercent), [100, 0, 100, 50])
        XCTAssertEqual(points[1].date, points[2].date)
        XCTAssertNotEqual(points[1].seriesID, points[2].seriesID)
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
    }

    func testDailyUsageHistoryFiltersAndSortsTheLastSevenDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 17,
            hour: 12
        )))
        let usage = [
            DailyTokenUsage(startDate: "2026-07-17", tokens: 700),
            DailyTokenUsage(startDate: "2026-07-10", tokens: 100),
            DailyTokenUsage(startDate: "not-a-date", tokens: 900),
            DailyTokenUsage(startDate: "2026-07-11", tokens: 200),
            DailyTokenUsage(startDate: "2026-07-18", tokens: 800),
            DailyTokenUsage(startDate: "2026-07-14", tokens: 500)
        ]

        let result = DailyUsageHistory.last(7, from: usage, through: now, calendar: calendar)

        XCTAssertEqual(result.map(\.startDate), ["2026-07-11", "2026-07-14", "2026-07-17"])
        XCTAssertEqual(result.map(\.tokens), [200, 500, 700])
    }

    func testRemainingHistoryKeepsSevenDaysAndReplacesTheCurrentQuarterHour() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiredDate = now.addingTimeInterval(-RemainingUsageHistory.retentionInterval - 1)
        let firstSnapshot = UsageSnapshot.make(windows: [
            RateLimitWindow(usedPercent: 40, windowDurationMins: 300, resetsAt: 2_000_001_000),
            RateLimitWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: 2_000_500_000)
        ], planType: "pro", updatedAt: now)
        let replacementSnapshot = UsageSnapshot.make(windows: [
            RateLimitWindow(usedPercent: 45, windowDurationMins: 300, resetsAt: 2_000_001_000),
            RateLimitWindow(usedPercent: 25, windowDurationMins: 10_080, resetsAt: 2_000_500_000)
        ], planType: "pro", updatedAt: now.addingTimeInterval(60))

        let history = RemainingUsageHistory.empty
            .recording(firstSnapshot, at: expiredDate)
            .recording(firstSnapshot, at: now)
            .recording(replacementSnapshot, at: now.addingTimeInterval(60))

        XCTAssertEqual(history.samples.count, 1)
        XCTAssertEqual(history.samples.first?.fiveHourRemainingPercent, 55)
        XCTAssertEqual(history.samples.first?.weeklyRemainingPercent, 75)
        XCTAssertEqual(history.samples.first?.capturedAt, now.addingTimeInterval(60))
    }

    func testRemainingHistoryFiltersRangesAndBreaksLinesAtGapsAndMissingWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let history = RemainingUsageHistory(samples: [
            .init(capturedAt: now.addingTimeInterval(-25 * 3_600), fiveHourRemainingPercent: nil, weeklyRemainingPercent: 90),
            .init(capturedAt: now.addingTimeInterval(-4 * 3_600), fiveHourRemainingPercent: nil, weeklyRemainingPercent: 80),
            .init(capturedAt: now.addingTimeInterval((-4 * 3_600) + 900), fiveHourRemainingPercent: nil, weeklyRemainingPercent: 78),
            .init(capturedAt: now.addingTimeInterval((-4 * 3_600) + 1_800), fiveHourRemainingPercent: nil, weeklyRemainingPercent: 100),
            .init(capturedAt: now.addingTimeInterval(-2 * 3_600), fiveHourRemainingPercent: nil, weeklyRemainingPercent: 95),
            .init(capturedAt: now.addingTimeInterval(-3_600), fiveHourRemainingPercent: nil, weeklyRemainingPercent: nil),
            .init(capturedAt: now.addingTimeInterval(-2_700), fiveHourRemainingPercent: nil, weeklyRemainingPercent: 92)
        ])

        let oneDayPoints = history.chartPoints(in: .oneDay, through: now)
            .filter { $0.kind == .weekly }
        XCTAssertEqual(oneDayPoints.map(\.remainingPercent), [80, 78, 100, 95, 92])
        XCTAssertEqual(oneDayPoints.map(\.segment), [0, 0, 0, 1, 2])

        let sevenDayPoints = history.chartPoints(in: .sevenDays, through: now)
            .filter { $0.kind == .weekly }
        XCTAssertEqual(sevenDayPoints.first?.remainingPercent, 90)
        XCTAssertEqual(sevenDayPoints.count, 6)
    }

    func testWidgetDisplayPreferencesUseSafeDefaultsAndPersistSelections() throws {
        let suiteName = "CodexRateWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WidgetDisplayPreferences.chartMode(defaults: defaults), .officialTokens)
        XCTAssertEqual(WidgetDisplayPreferences.historyRange(defaults: defaults), .oneDay)

        WidgetDisplayPreferences.save(chartMode: .remainingHistory, defaults: defaults)
        WidgetDisplayPreferences.save(historyRange: .sevenDays, defaults: defaults)

        XCTAssertEqual(WidgetDisplayPreferences.chartMode(defaults: defaults), .remainingHistory)
        XCTAssertEqual(WidgetDisplayPreferences.historyRange(defaults: defaults), .sevenDays)
    }

    func testDisplayLanguagePreferencesUseSystemDefaultAndPersistSelections() throws {
        let suiteName = "CodexRateWidgetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DisplayLanguagePreferences.load(defaults: defaults), .system)

        DisplayLanguagePreferences.save(.english, defaults: defaults)
        XCTAssertEqual(DisplayLanguagePreferences.load(defaults: defaults), .english)

        defaults.set("unsupported", forKey: "display-language-v1")
        XCTAssertEqual(DisplayLanguagePreferences.load(defaults: defaults), .system)
    }

    func testExplicitDisplayLanguageOverridesSystemLocalization() {
        let english = DisplayLanguage.english.locale
        let japanese = DisplayLanguage.japanese.locale

        XCTAssertEqual(AppLocalization.string("Weekly", locale: english), "Weekly")
        XCTAssertEqual(AppLocalization.string("Weekly", locale: japanese), "週間")
        XCTAssertEqual(DisplayLanguage.english.displayName(locale: japanese), "英語")
        XCTAssertEqual(DisplayLanguage.japanese.displayName(locale: english), "Japanese")

        let weekly = RateLimitWindow(usedPercent: 25, windowDurationMins: 10_080, resetsAt: nil)
        XCTAssertEqual(weekly.durationLabel(locale: english), "Weekly")
        XCTAssertEqual(weekly.durationLabel(locale: japanese), "週間")
    }

    func testBuildVersionInfoFormatsResolvedBundleValues() throws {
        let version = try XCTUnwrap(BuildVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.0.0 ",
            "CFBundleVersion": "3"
        ]))

        XCTAssertEqual(version.shortVersion, "1.0.0")
        XCTAssertEqual(version.buildNumber, "3")
        XCTAssertEqual(version.compactLabel, "v1.0.0")
        XCTAssertTrue(version.accessibilityLabel.contains("1.0.0"))
        XCTAssertFalse(version.accessibilityLabel.contains("3"))
    }

    func testBuildVersionInfoRejectsMissingOrUnexpandedValues() {
        XCTAssertNil(BuildVersionInfo(infoDictionary: [:]))
        XCTAssertNil(BuildVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "3"
        ]))
    }

    func testJapaneseLocalizationIsBundled() throws {
        let localizationPath = try XCTUnwrap(
            Bundle.main.path(forResource: "ja", ofType: "lproj")
        )
        let japaneseBundle = try XCTUnwrap(Bundle(path: localizationPath))

        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "5 hours", value: "5 hours", table: nil),
            "5時間"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Local Estimate · Unofficial",
                value: "Local Estimate · Unofficial",
                table: nil
            ),
            "ローカル推定・非公式"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "Weekly reset", value: "Weekly reset", table: nil),
            "週間リセット"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Recorded on This Mac · Every 15 Minutes",
                value: "Recorded on This Mac · Every 15 Minutes",
                table: nil
            ),
            "このMacの記録・15分間隔"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "Daily Usage", value: "Daily Usage", table: nil),
            "日別使用量"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "Remaining History",
                value: "Remaining History",
                table: nil
            ),
            "残り推移"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(forKey: "Language", value: "Language", table: nil),
            "言語"
        )
        XCTAssertEqual(
            japaneseBundle.localizedString(
                forKey: "System Default",
                value: "System Default",
                table: nil
            ),
            "システム設定"
        )
    }

    func testProjectUsageOnlyIncludesThreadsUpdatedWithinSevenDays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databasePath = directory.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databasePath, &database), SQLITE_OK)
        guard let database else { return XCTFail("Could not create test database") }
        defer { sqlite3_close(database) }

        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads (cwd TEXT, updated_at INTEGER, tokens_used INTEGER, thread_source TEXT)", nil, nil, nil), SQLITE_OK)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let calendar = Calendar.current
        let recent = Int(calendar.startOfDay(for: calendar.date(byAdding: .day, value: -6, to: now)!).timeIntervalSince1970)
        let previousDay = Int(calendar.date(byAdding: .second, value: -1, to: Date(timeIntervalSince1970: TimeInterval(recent)))!.timeIntervalSince1970)
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO threads VALUES ('/Recent', \(recent), 120, 'user'), ('/Recent', \(recent), 5000, 'subagent'), ('/PreviousDay', \(previousDay), 777, 'user')", nil, nil, nil), SQLITE_OK)

        XCTAssertEqual(
            ProjectUsageAnalyzer.analyze(databasePath: databasePath, days: 7, now: now),
            []
        )
        XCTAssertEqual(
            ProjectUsageAnalyzer.analyze(
                databasePath: databasePath,
                days: 7,
                now: now,
                officialTotalTokens: 0
            ),
            []
        )

        let normalized = ProjectUsageAnalyzer.analyze(
            databasePath: databasePath,
            days: 7,
            now: now,
            officialTotalTokens: 1_000
        )
        XCTAssertEqual(normalized, [ProjectTokenUsage(path: "/Recent", tokens: 1_000)])
    }

    func testUnitTestHostDoesNotStartLiveMonitoring() {
        XCTAssertFalse(AppRuntime.shouldStartMonitoring())
        XCTAssertFalse(AppRuntime.shouldStartMonitoring(environment: [
            "XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"
        ]))
        XCTAssertTrue(AppRuntime.shouldStartMonitoring(environment: [:]))
    }

    func testAccountUsageDecodingKeepsDailyDataWhenSummaryIsMissing() throws {
        let data = Data(#"{"dailyUsageBuckets":[{"startDate":"2026-07-16","tokens":123}]}"#.utf8)

        let usage = try JSONDecoder().decode(CodexRateLimitClient.AccountUsageResult.self, from: data)

        XCTAssertEqual(usage.dailyUsageBuckets, [
            DailyTokenUsage(startDate: "2026-07-16", tokens: 123)
        ])
        XCTAssertNil(usage.summary)
    }

    func testLiveCodexResponseWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_CODEX_TEST"] == "1" else {
            throw XCTSkip("Skipped by default because this test uses the local Codex account.")
        }
        let snapshot = try await CodexRateLimitClient().fetch()
        XCTAssertTrue(snapshot.weekly != nil || snapshot.fiveHour != nil || !snapshot.otherWindows.isEmpty)
    }
}
