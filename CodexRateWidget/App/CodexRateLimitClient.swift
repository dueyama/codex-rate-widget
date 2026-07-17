import Foundation

actor CodexRateLimitClient {
    enum ClientError: LocalizedError {
        case codexNotFound
        case launchFailed(String)
        case timeout
        case malformedResponse(String)
        case processExited(Int32, String)
        case server(String)
        case noCodexBucket

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return String(localized: "Codex CLI was not found. Install `codex`, then restart the app.")
            case let .launchFailed(message):
                return String(format: String(localized: "Could not launch Codex CLI: %@"), message)
            case .timeout:
                return String(localized: "Timed out while fetching Codex usage.")
            case let .malformedResponse(details):
                let suffix = details.isEmpty ? "" : " \(details)"
                return String(format: String(localized: "Unexpected response from Codex.%@"), suffix)
            case let .processExited(code, details):
                let suffix = details.isEmpty ? "" : " \(details)"
                return String(
                    format: String(localized: "Codex CLI exited before responding. (exit code %d)%@"),
                    code,
                    suffix
                )
            case let .server(message):
                return String(format: String(localized: "Codex: %@"), message)
            case .noCodexBucket:
                return String(localized: "Codex did not return a usage-limit window.")
            }
        }
    }

    private struct RateLimitsRPCResponse: Decodable {
        let id: Int?
        let result: RateLimitsResult?
        let error: RPCError?
    }

    private struct UsageRPCResponse: Decodable {
        let id: Int?
        let result: AccountUsageResult?
        let error: RPCError?
    }

    private struct RPCError: Decodable { let message: String }

    private struct RateLimitsResult: Decodable {
        let rateLimits: RateLimitSnapshot
        let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    }

    private struct RateLimitSnapshot: Decodable {
        let limitId: String?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let planType: String?
    }

    // Internal so the resilience of partial app-server responses can be tested.
    struct AccountUsageResult: Decodable {
        struct Summary: Decodable { let lifetimeTokens: Int64? }
        let dailyUsageBuckets: [DailyTokenUsage]?
        let summary: Summary?
    }

    func fetch() async throws -> UsageSnapshot {
        let executable = try findCodexExecutable()
        let snapshot = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            let standardInput = Pipe()
            let outputHandle = standardOutput.fileHandleForReading
            let errorHandle = standardError.fileHandleForReading
            let inputHandle = standardInput.fileHandleForWriting
            let state = RequestState(
                continuation: continuation,
                process: process,
                outputHandle: outputHandle,
                errorHandle: errorHandle,
                inputHandle: inputHandle
            )

            process.executableURL = executable
            process.arguments = ["app-server", "--stdio"]
            process.standardOutput = standardOutput
            process.standardError = standardError
            process.standardInput = standardInput
            process.environment = codexProcessEnvironment(for: executable)

            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // FileHandle can keep reporting EOF while a readability
                    // handler remains installed, causing a persistent CPU spin.
                    handle.readabilityHandler = nil
                    return
                }
                state.consume(data: data)
            }

            errorHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // Stop monitoring at EOF for the same reason as stdout.
                    handle.readabilityHandler = nil
                    return
                }
                state.consumeStandardError(data: data)
            }

            process.terminationHandler = { terminatedProcess in
                state.processTerminated(exitCode: terminatedProcess.terminationStatus)
            }

            do {
                try process.run()
                let clientVersion = BuildVersionInfo.current?.shortVersion ?? "unknown"
                let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-rate-widget","title":"Codex Rate Widget","version":"\#(clientVersion)"},"capabilities":{"experimentalApi":true}}}"#
                let rateLimits = #"{"id":2,"method":"account/rateLimits/read","params":null}"#
                let accountUsage = #"{"id":3,"method":"account/usage/read","params":null}"#
                let request = Data("\(initialize)\n\(rateLimits)\n\(accountUsage)\n".utf8)
                try inputHandle.write(contentsOf: request)
                state.armTimeout(seconds: 45)
            } catch {
                state.finish(.failure(ClientError.launchFailed(error.localizedDescription)))
            }
        }
        let projects = ProjectUsageAnalyzer.analyze(officialTotalTokens: recentOfficialTokens(snapshot.dailyTokenUsage))
        return .make(
            windows: [snapshot.fiveHour, snapshot.weekly].compactMap { $0 } + snapshot.otherWindows,
            planType: snapshot.planType,
            dailyTokenUsage: snapshot.dailyTokenUsage,
            lifetimeTokens: snapshot.lifetimeTokens,
            projectUsage: projects,
            updatedAt: snapshot.updatedAt
        )
    }

    private func recentOfficialTokens(_ usage: [DailyTokenUsage], now: Date = .now) -> Int64? {
        let total = DailyUsageHistory.last(7, from: usage, through: now)
            .reduce(Int64(0)) { $0 + $1.tokens }
        return total > 0 ? total : nil
    }

    private func findCodexExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = []

        if let override = environment["CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }

        candidates += (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }

        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent("bin/codex").path,
            home.appendingPathComponent(".npm-global/bin/codex").path,
            home.appendingPathComponent(".volta/bin/codex").path,
            home.appendingPathComponent(".asdf/shims/codex").path,
            home.appendingPathComponent(".local/share/mise/shims/codex").path,
            home.appendingPathComponent(".local/share/mise/installs/node/latest/bin/codex").path
        ]

        let nvmVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates += versions
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                .map { $0.appendingPathComponent("bin/codex").path }
        }

        var checked = Set<String>()
        for path in candidates where checked.insert(path).inserted && FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ClientError.codexNotFound
    }

    private func codexProcessEnvironment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let paths = requiredPaths.filter { !existingPaths.contains($0) } + existingPaths
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    private final class RequestState: @unchecked Sendable {
        private struct Storage {
            var buffer = Data()
            var standardErrorBuffer = Data()
            var completed = false
            var timeoutTask: Task<Void, Never>?
            var rateLimitsResult: RateLimitsResult?
            var accountUsageResult: AccountUsageResult?
        }

        private enum RateLimitsCompletion {
            case alreadyCompleted
            case unavailable
            case ready(RateLimitsResult, AccountUsageResult?)
        }

        private let lock = NSLock()
        private var storage = Storage()
        private let continuation: CheckedContinuation<UsageSnapshot, Error>
        private let process: Process
        private let outputHandle: FileHandle
        private let errorHandle: FileHandle
        private let inputHandle: FileHandle

        init(
            continuation: CheckedContinuation<UsageSnapshot, Error>,
            process: Process,
            outputHandle: FileHandle,
            errorHandle: FileHandle,
            inputHandle: FileHandle
        ) {
            self.continuation = continuation
            self.process = process
            self.outputHandle = outputHandle
            self.errorHandle = errorHandle
            self.inputHandle = inputHandle
        }

        func armTimeout(seconds: UInt64) {
            let task = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
                self?.timeoutReached()
            }
            let previousTaskAndCompletion = withLock { storage in
                let previousTask = storage.timeoutTask
                guard !storage.completed else { return (previousTask, true) }
                storage.timeoutTask = task
                return (previousTask, false)
            }
            previousTaskAndCompletion.0?.cancel()
            if previousTaskAndCompletion.1 {
                task.cancel()
            }
        }

        func consumeStandardError(data: Data) {
            withLock { storage in
                guard !storage.completed, storage.standardErrorBuffer.count < 8_192 else { return }
                storage.standardErrorBuffer.append(data.prefix(8_192 - storage.standardErrorBuffer.count))
            }
        }

        func consume(data: Data) {
            let completeLines = withLock { storage -> [Data] in
                guard !storage.completed else { return [] }
                storage.buffer.append(data)
                let lines = storage.buffer.split(separator: 0x0A, omittingEmptySubsequences: true)
                let endsWithNewline = storage.buffer.last == 0x0A
                let completeLines = endsWithNewline ? ArraySlice(lines) : lines.dropLast()
                let completeData = completeLines.map { Data($0) }
                if !endsWithNewline, let last = lines.last {
                    storage.buffer = Data(last)
                } else {
                    storage.buffer.removeAll(keepingCapacity: true)
                }
                return completeData
            }

            for line in completeLines {
                if let response = try? JSONDecoder().decode(RateLimitsRPCResponse.self, from: line), response.id == 2 {
                    if let error = response.error {
                        finish(.failure(ClientError.server(error.message)))
                        return
                    }
                    guard let result = response.result else {
                        finish(.failure(ClientError.malformedResponse(String(localized: "rateLimits/read result was empty."))))
                        return
                    }
                    withLock { storage in
                        guard !storage.completed else { return }
                        storage.rateLimitsResult = result
                    }
                } else if let response = try? JSONDecoder().decode(UsageRPCResponse.self, from: line), response.id == 3 {
                    if response.error != nil {
                        // Keep showing remaining capacity even when detailed daily data is unavailable.
                        withLock { storage in
                            guard !storage.completed else { return }
                            storage.accountUsageResult = AccountUsageResult(
                                dailyUsageBuckets: nil,
                                summary: nil
                            )
                        }
                        completeIfReady()
                        return
                    }
                    guard let result = response.result else {
                        withLock { storage in
                            guard !storage.completed else { return }
                            storage.accountUsageResult = AccountUsageResult(
                                dailyUsageBuckets: nil,
                                summary: nil
                            )
                        }
                        completeIfReady()
                        return
                    }
                    withLock { storage in
                        guard !storage.completed else { return }
                        storage.accountUsageResult = result
                    }
                }
                completeIfReady()
            }
        }

        private func timeoutReached() {
            if completeFromRateLimits() { return }
            finish(.failure(ClientError.timeout))
        }

        private func completeIfReady() {
            let results = withLock { storage -> (RateLimitsResult, AccountUsageResult)? in
                guard
                    !storage.completed,
                    let rateLimits = storage.rateLimitsResult,
                    let accountUsage = storage.accountUsageResult
                else { return nil }
                return (rateLimits, accountUsage)
            }
            guard let results else { return }
            finish(completionResult(rateLimits: results.0, accountUsage: results.1))
        }

        @discardableResult
        private func completeFromRateLimits() -> Bool {
            let completion = withLock { storage -> RateLimitsCompletion in
                if storage.completed { return .alreadyCompleted }
                guard let rateLimits = storage.rateLimitsResult else { return .unavailable }
                return .ready(rateLimits, storage.accountUsageResult)
            }
            switch completion {
            case .alreadyCompleted:
                return true
            case .unavailable:
                return false
            case let .ready(rateLimits, accountUsage):
                finish(completionResult(rateLimits: rateLimits, accountUsage: accountUsage))
                return true
            }
        }

        private func completionResult(
            rateLimits: RateLimitsResult,
            accountUsage: AccountUsageResult?
        ) -> Result<UsageSnapshot, Error> {
            let bucket = rateLimits.rateLimitsByLimitId?["codex"] ?? rateLimits.rateLimits
            let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
            guard bucket.limitId == "codex" || rateLimits.rateLimitsByLimitId?["codex"] != nil else {
                return .failure(ClientError.noCodexBucket)
            }
            return .success(.make(
                windows: windows,
                planType: bucket.planType,
                dailyTokenUsage: accountUsage?.dailyUsageBuckets ?? [],
                lifetimeTokens: accountUsage?.summary?.lifetimeTokens
            ))
        }

        func processTerminated(exitCode: Int32) {
            Task { [weak self] in
                // terminationHandler can run before stdout's final readabilityHandler callback.
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if self.completeFromRateLimits() { return }
                self.finish(.failure(ClientError.processExited(exitCode, self.standardErrorSummary())))
            }
        }

        private func standardErrorSummary() -> String {
            let standardErrorBuffer = withLock { storage in storage.standardErrorBuffer }
            guard let text = String(data: standardErrorBuffer, encoding: .utf8) else { return "" }
            return text
                .split(separator: "\n")
                .suffix(2)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func finish(_ result: Result<UsageSnapshot, Error>) {
            let completion = withLock { storage -> (claimed: Bool, timeoutTask: Task<Void, Never>?) in
                guard !storage.completed else { return (false, nil) }
                storage.completed = true
                let timeoutTask = storage.timeoutTask
                storage.timeoutTask = nil
                return (true, timeoutTask)
            }
            guard completion.claimed else { return }
            completion.timeoutTask?.cancel()
            // Break all Pipe/Process callback retain cycles before terminating
            // the short-lived app-server process.
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            try? inputHandle.close()
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            continuation.resume(with: result)
        }

        private func withLock<T>(_ body: (inout Storage) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }
    }
}
