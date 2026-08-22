import Foundation

enum RemainingHistoryRange: String, Codable, CaseIterable, Sendable {
    case oneDay
    case sevenDays

    var duration: TimeInterval {
        switch self {
        case .oneDay: 86_400
        case .sevenDays: 7 * 86_400
        }
    }
}

enum RemainingLimitKind: String, CaseIterable, Hashable, Sendable {
    case fiveHour
    case weekly
}

struct RemainingUsageSample: Codable, Equatable, Identifiable, Sendable {
    let capturedAt: Date
    let fiveHourRemainingPercent: Int?
    let weeklyRemainingPercent: Int?

    var id: Date { capturedAt }

    init(
        capturedAt: Date,
        fiveHourRemainingPercent: Int?,
        weeklyRemainingPercent: Int?
    ) {
        self.capturedAt = capturedAt
        self.fiveHourRemainingPercent = fiveHourRemainingPercent.map(Self.clamp)
        self.weeklyRemainingPercent = weeklyRemainingPercent.map(Self.clamp)
    }

    init(snapshot: UsageSnapshot, capturedAt: Date) {
        self.init(
            capturedAt: capturedAt,
            fiveHourRemainingPercent: snapshot.fiveHour?.remainingPercent,
            weeklyRemainingPercent: snapshot.weekly?.remainingPercent
        )
    }

    func remainingPercent(for kind: RemainingLimitKind) -> Int? {
        switch kind {
        case .fiveHour: fiveHourRemainingPercent
        case .weekly: weeklyRemainingPercent
        }
    }

    private static func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}

struct RemainingUsageChartPoint: Equatable, Identifiable, Sendable {
    let capturedAt: Date
    let remainingPercent: Int
    let kind: RemainingLimitKind
    let segment: Int

    var id: String {
        "\(kind.rawValue)-\(capturedAt.timeIntervalSince1970)"
    }

    var seriesID: String {
        "\(kind.rawValue)-\(segment)"
    }
}

enum WeeklyZeroProjection: Equatable, Sendable {
    case collectingData
    case noDownwardTrend
    case projected(Date)
}

enum WeeklyZeroProjectionFormatting {
    static func shortLabel(
        _ projection: WeeklyZeroProjection,
        resetDate: Date,
        locale: Locale = .current
    ) -> String {
        switch projection {
        case .collectingData:
            AppLocalization.string("Projected 0%: collecting data", locale: locale)
        case .noDownwardTrend:
            AppLocalization.string("Projected 0%: no downward trend", locale: locale)
        case .projected(let date) where date >= resetDate:
            AppLocalization.string("Projected 0%: after reset", locale: locale)
        case .projected(let date):
            AppLocalization.format(
                "Projected 0%%: %@",
                locale: locale,
                ResetScheduleFormatting.dateTime(date, locale: locale)
            )
        }
    }
}

struct RemainingUsageHistory: Codable, Equatable, Sendable {
    static let retentionInterval: TimeInterval = 7 * 86_400
    static let sampleInterval: TimeInterval = 15 * 60
    static let maximumContinuousGap: TimeInterval = 30 * 60
    static let zeroProjectionMinimumSampleCount = 8
    static let zeroProjectionMinimumDuration: TimeInterval = 6 * 3_600
    static let zeroProjectionMaximumStaleness: TimeInterval = 30 * 60

    let samples: [RemainingUsageSample]

    static let empty = RemainingUsageHistory(samples: [])

    func recording(_ snapshot: UsageSnapshot, at capturedAt: Date? = nil) -> RemainingUsageHistory {
        let date = capturedAt ?? snapshot.updatedAt
        guard date != .distantPast else { return self }

        let cutoff = date.addingTimeInterval(-Self.retentionInterval)
        let latestAllowedDate = date.addingTimeInterval(Self.sampleInterval)
        var samplesByBucket: [Int64: RemainingUsageSample] = [:]

        for sample in samples where sample.capturedAt >= cutoff && sample.capturedAt <= latestAllowedDate {
            samplesByBucket[Self.bucket(for: sample.capturedAt)] = sample
        }

        samplesByBucket[Self.bucket(for: date)] = RemainingUsageSample(
            snapshot: snapshot,
            capturedAt: date
        )

        return RemainingUsageHistory(samples: samplesByBucket.values.sorted {
            $0.capturedAt < $1.capturedAt
        })
    }

    func chartPoints(
        in range: RemainingHistoryRange,
        through endDate: Date
    ) -> [RemainingUsageChartPoint] {
        let startDate = endDate.addingTimeInterval(-range.duration)
        let relevantSamples = samples
            .filter { $0.capturedAt >= startDate && $0.capturedAt <= endDate }
            .sorted { $0.capturedAt < $1.capturedAt }

        return RemainingLimitKind.allCases.flatMap { kind in
            chartPoints(for: kind, from: relevantSamples)
        }
    }

    func weeklyZeroProjection(
        for window: RateLimitWindow?,
        through endDate: Date
    ) -> WeeklyZeroProjection {
        guard
            let window,
            window.windowDurationMins == WeeklyPace.durationMinutes,
            let resetDate = window.resetDate
        else { return .collectingData }

        let cycleStart = resetDate.addingTimeInterval(-WeeklyPace.duration)
        let cycleSamples = samples
            .filter {
                $0.capturedAt >= cycleStart
                    && $0.capturedAt <= endDate
                    && $0.weeklyRemainingPercent != nil
            }
            .sorted { $0.capturedAt < $1.capturedAt }

        guard
            cycleSamples.count >= Self.zeroProjectionMinimumSampleCount,
            let firstDate = cycleSamples.first?.capturedAt,
            let lastDate = cycleSamples.last?.capturedAt,
            lastDate.timeIntervalSince(firstDate) >= Self.zeroProjectionMinimumDuration,
            endDate.timeIntervalSince(lastDate) <= Self.zeroProjectionMaximumStaleness
        else { return .collectingData }

        let observations = cycleSamples.compactMap { sample -> (x: Double, y: Double)? in
            guard let remaining = sample.weeklyRemainingPercent else { return nil }
            return (
                x: sample.capturedAt.timeIntervalSince(firstDate),
                y: Double(remaining)
            )
        }
        let count = Double(observations.count)
        let meanX = observations.reduce(0) { $0 + $1.x } / count
        let meanY = observations.reduce(0) { $0 + $1.y } / count
        let covariance = observations.reduce(0) {
            $0 + ($1.x - meanX) * ($1.y - meanY)
        }
        let variance = observations.reduce(0) {
            $0 + ($1.x - meanX) * ($1.x - meanX)
        }
        guard variance > 0 else { return .collectingData }

        let slope = covariance / variance
        guard slope < 0 else { return .noDownwardTrend }
        let intercept = meanY - slope * meanX
        let zeroOffset = -intercept / slope
        guard zeroOffset.isFinite else { return .noDownwardTrend }

        let projectedDate = firstDate.addingTimeInterval(zeroOffset)
        guard projectedDate > endDate else { return .noDownwardTrend }
        return .projected(projectedDate)
    }

    private func chartPoints(
        for kind: RemainingLimitKind,
        from samples: [RemainingUsageSample]
    ) -> [RemainingUsageChartPoint] {
        var points: [RemainingUsageChartPoint] = []
        var previousSample: RemainingUsageSample?
        var segment = 0

        for sample in samples {
            guard let remainingPercent = sample.remainingPercent(for: kind) else {
                previousSample = nil
                continue
            }

            if let previousSample {
                let hasLongGap = sample.capturedAt.timeIntervalSince(previousSample.capturedAt)
                    > Self.maximumContinuousGap
                if hasLongGap {
                    segment += 1
                }
            } else if !points.isEmpty {
                segment += 1
            }

            points.append(RemainingUsageChartPoint(
                capturedAt: sample.capturedAt,
                remainingPercent: remainingPercent,
                kind: kind,
                segment: segment
            ))
            previousSample = sample
        }

        return points
    }

    private static func bucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / sampleInterval))
    }
}

enum SharedRemainingUsageHistoryStore {
    static var historyURL: URL? {
        guard let appGroup = WidgetConstants.appGroup else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(WidgetConstants.remainingHistoryFileName, isDirectory: false)
    }

    static func load() -> RemainingUsageHistory {
        guard
            let historyURL,
            let data = try? Data(contentsOf: historyURL),
            let history = try? JSONDecoder().decode(RemainingUsageHistory.self, from: data)
        else { return .empty }
        return history
    }

    @discardableResult
    static func record(_ snapshot: UsageSnapshot) throws -> RemainingUsageHistory {
        let history = load().recording(snapshot)
        try save(history)
        return history
    }

    static func save(_ history: RemainingUsageHistory) throws {
        guard let historyURL else {
            throw SharedUsageStore.StoreError.appGroupUnavailable
        }
        let data = try JSONEncoder().encode(history)
        try data.write(to: historyURL, options: .atomic)
    }
}
