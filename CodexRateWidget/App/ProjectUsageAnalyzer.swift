import Foundation
import SQLite3

enum ProjectUsageAnalyzer {
    static func analyze(days: Int = 7, now: Date = .now, officialTotalTokens: Int64? = nil) -> [ProjectTokenUsage] {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let databasePath = URL(fileURLWithPath: codexHome).appendingPathComponent("state_5.sqlite").path
        return analyze(databasePath: databasePath, days: days, now: now, officialTotalTokens: officialTotalTokens)
    }

    static func analyze(databasePath: String, days: Int, now: Date, officialTotalTokens: Int64? = nil) -> [ProjectTokenUsage] {
        // Local thread counters are cumulative and can greatly exceed the
        // requested time window. They are safe only as relative weights for an
        // official seven-day total, never as display values on their own.
        guard let officialTotalTokens, officialTotalTokens > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &database, flags, nil) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT cwd, SUM(tokens_used) AS total_tokens
            FROM threads
            WHERE updated_at >= ?
              AND cwd <> ''
              AND COALESCE(thread_source, '') <> 'subagent'
            GROUP BY cwd
            HAVING total_tokens > 0
            ORDER BY total_tokens DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let calendar = Calendar.current
        let cutoffDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now
        )
        let cutoff = Int64(cutoffDate.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 1, cutoff)

        var rawProjects: [ProjectTokenUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cwdBytes = sqlite3_column_text(statement, 0) else { continue }
            let cwd = String(cString: cwdBytes)
            let tokens = sqlite3_column_int64(statement, 1)
            rawProjects.append(ProjectTokenUsage(path: cwd, tokens: tokens))
        }

        guard !rawProjects.isEmpty else { return [] }

        let rawTotal = rawProjects.reduce(Int64(0)) { $0 + $1.tokens }
        guard rawTotal > 0 else { return [] }

        return rawProjects.prefix(5).map { project in
            let share = Double(project.tokens) / Double(rawTotal)
            return ProjectTokenUsage(
                path: project.path,
                tokens: Int64((Double(officialTotalTokens) * share).rounded())
            )
        }
    }
}
