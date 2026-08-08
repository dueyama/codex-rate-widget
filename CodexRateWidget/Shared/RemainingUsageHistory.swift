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

struct RemainingUsageHistory: Codable, Equatable, Sendable {
    static let retentionInterval: TimeInterval = 7 * 86_400
    static let sampleInterval: TimeInterval = 15 * 60
    static let maximumContinuousGap: TimeInterval = 30 * 60

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
