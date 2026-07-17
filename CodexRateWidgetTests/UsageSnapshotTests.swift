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

    func testBuildVersionInfoFormatsResolvedBundleValues() throws {
        let version = try XCTUnwrap(BuildVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.0.0 ",
            "CFBundleVersion": "3"
        ]))

        XCTAssertEqual(version.shortVersion, "1.0.0")
        XCTAssertEqual(version.buildNumber, "3")
        XCTAssertEqual(version.compactLabel, "v1.0.0 (3)")
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
