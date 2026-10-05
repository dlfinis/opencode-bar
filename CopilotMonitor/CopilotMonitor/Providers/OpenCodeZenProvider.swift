import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeZenProvider")

enum AlibabaActivityCache {
    private static let lock = NSLock()
    private static var value: [String: OpenCodeZenProvider.AlibabaModelActivity] = [:]

    static func set(_ activity: [String: OpenCodeZenProvider.AlibabaModelActivity]) {
        lock.lock()
        value = activity
        lock.unlock()
    }

    static func get() -> [String: OpenCodeZenProvider.AlibabaModelActivity] {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Personal Token Plan monthly quota tiers (Singapore, Credits per 30-day
/// subscription cycle). Raw value is the monthly quota, so presets compare by
/// cost value rather than by name (see the subscription preset rule).
enum AlibabaQuotaTier: Int, CaseIterable {
    case lite = 11_500
    case essential = 25_500
    case standard = 45_000
    case pro = 180_000

    var label: String {
        switch self {
        case .lite: return "Lite (11,500)"
        case .essential: return "Essential (25,500)"
        case .standard: return "Standard (45,000)"
        case .pro: return "Pro (180,000)"
        }
    }
}

/// One calibration point: the console usage percentage read at a moment plus
/// the local OpenCode Alibaba token/message totals at that same moment. Two
/// samples close the loop for a token→Credit and Credits/hour inference.
struct AlibabaQuotaSample: Codable, Equatable {
    let date: Date
    let percentUsed: Double
    let totalTokens: Int
    let nonCacheTokens: Int
    let messages: Int
}

struct AlibabaQuotaProjection: Equatable {
    let usedCredits: Double
    let remainingCredits: Double
    let sampleCount: Int
    let creditsPerHour: Double?
    let creditsPerDay: Double?
    let daysToExhaust: Double?
    let creditsPerMessage: Double?
    let rateWindowHours: Double?
}

/// Manual quota calibration store. The console percentage is the only real
/// signal; Credits/day and days-to-exhaust come from the delta between the two
/// most recent samples. Persists to `UserDefaults` like SubscriptionSettings.
final class AlibabaQuotaCalibration {
    static let shared = AlibabaQuotaCalibration()

    static let defaultMonthlyQuota = AlibabaQuotaTier.standard.rawValue
    private static let quotaKey = "alibaba_quota_v1.monthlyQuota"
    private static let samplesKey = "alibaba_quota_v1.samples"
    private static let maxSamples = 120

    private let defaults: UserDefaults
    private(set) var samples: [AlibabaQuotaSample] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.samplesKey),
           let decoded = try? JSONDecoder().decode([AlibabaQuotaSample].self, from: data) {
            samples = decoded.sorted { $0.date < $1.date }
        }
    }

    var monthlyQuota: Int {
        get {
            let stored = defaults.integer(forKey: Self.quotaKey)
            return stored > 0 ? stored : Self.defaultMonthlyQuota
        }
        set {
            defaults.set(max(1, newValue), forKey: Self.quotaKey)
        }
    }

    var hasConfiguredQuota: Bool {
        defaults.object(forKey: Self.quotaKey) != nil
    }

    var hasSamples: Bool { !samples.isEmpty }

    /// Records a sample from the current Alibaba activity cache. Token/message
    /// totals are the same 30-day basis across samples, so their difference
    /// approximates consumption between the two console reads.
    func recordSnapshot(percent: Double, now: Date = Date()) {
        let activity = AlibabaActivityCache.get()
        var totalTokens = 0
        var nonCacheTokens = 0
        var messages = 0
        for model in activity.values {
            let nonCache = model.inputTokens + model.outputTokens
            nonCacheTokens += nonCache
            totalTokens += nonCache + model.cacheReadTokens + model.cacheWriteTokens
            messages += model.messages
        }
        append(AlibabaQuotaSample(
            date: now,
            percentUsed: percent,
            totalTokens: totalTokens,
            nonCacheTokens: nonCacheTokens,
            messages: messages
        ))
        save()
        debugLog("Alibaba quota snapshot recorded: \(percent)% (samples=\(samples.count))")
    }

    func clearSamples() {
        samples = []
        defaults.removeObject(forKey: Self.samplesKey)
        debugLog("Alibaba quota samples cleared")
    }

    func currentProjection() -> AlibabaQuotaProjection? {
        Self.projection(samples: samples, monthlyQuota: monthlyQuota)
    }

    private func append(_ sample: AlibabaQuotaSample) {
        samples.append(sample)
        samples.sort { $0.date < $1.date }
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(samples) {
            defaults.set(data, forKey: Self.samplesKey)
        }
    }

    /// Pure projection so the arithmetic is unit-testable without the store.
    static func projection(samples: [AlibabaQuotaSample], monthlyQuota: Int) -> AlibabaQuotaProjection? {
        guard monthlyQuota > 0,
              let latest = samples.max(by: { $0.date < $1.date }) else {
            return nil
        }

        let quota = Double(monthlyQuota)
        let used = latest.percentUsed / 100.0 * quota
        let remaining = max(0, quota - used)

        var creditsPerHour: Double?
        var creditsPerMessage: Double?
        var rateWindowHours: Double?

        let sorted = samples.sorted { $0.date < $1.date }
        if sorted.count >= 2 {
            let earlier = sorted[sorted.count - 2]
            let later = sorted[sorted.count - 1]
            let hours = later.date.timeIntervalSince(earlier.date) / 3600.0
            let deltaCredits = (later.percentUsed - earlier.percentUsed) / 100.0 * quota
            if hours > 0, deltaCredits > 0 {
                creditsPerHour = deltaCredits / hours
                rateWindowHours = hours
                let deltaMessages = later.messages - earlier.messages
                if deltaMessages > 0 {
                    creditsPerMessage = deltaCredits / Double(deltaMessages)
                }
            }
        }

        let creditsPerDay = creditsPerHour.map { $0 * 24.0 }
        let daysToExhaust: Double?
        if let perDay = creditsPerDay, perDay > 0 {
            daysToExhaust = remaining / perDay
        } else {
            daysToExhaust = nil
        }

        return AlibabaQuotaProjection(
            usedCredits: used,
            remainingCredits: remaining,
            sampleCount: samples.count,
            creditsPerHour: creditsPerHour,
            creditsPerDay: creditsPerDay,
            daysToExhaust: daysToExhaust,
            creditsPerMessage: creditsPerMessage,
            rateWindowHours: rateWindowHours
        )
    }
}


private func debugLog(_ message: String) {
    let msg = "[\(Date())] OpenCodeZen: \(message)\n"
    if let data = msg.data(using: .utf8) {
        let path = "/tmp/opencode_debug.log"
        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Provider for OpenCode Zen usage tracking via CLI stats.
/// Tracks current summary only and does not build historical time-series.
final class OpenCodeZenProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeZen
    let type: ProviderType = .payAsYouGo
    let fetchTimeout: TimeInterval = 60.0
    private static let alibabaStatsRefreshInterval: TimeInterval = 5 * 60
    private var lastAlibabaStatsAttempt: Date?
    private var cachedAlibabaActivity: [String: AlibabaModelActivity] = [:]

    struct AlibabaModelActivity: Equatable {
        var messages: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
    }

    /// Path to opencode CLI binary (lazily resolved)
    private lazy var opencodePath: URL? = {
        findOpenCodeBinary()
    }()

    /// Cached description of where the binary was found
    private var binarySourceDescription: String = "unknown"

    /// Finds opencode binary using multiple strategies:
    /// 1. Try "opencode" command directly via PATH (user's current environment)
    /// 2. Try "opencode" via login shell PATH (captures shell profile additions)
    /// 3. Fallback to common hardcoded paths
    private func findOpenCodeBinary() -> URL? {
        logger.info("OpenCodeZen: Searching for opencode binary...")
        debugLog("Starting opencode binary search")

        // Strategy 1: Try "which opencode" in current environment
        if let path = findBinaryViaWhich() {
            logger.info("OpenCodeZen: Found via 'which': \(path.path)")
            debugLog("Found via 'which': \(path.path)")
            binarySourceDescription = "PATH (\(path.path))"
            return path
        }

        // Strategy 2: Try via login shell to get user's full PATH
        if let path = findBinaryViaLoginShell() {
            logger.info("OpenCodeZen: Found via login shell: \(path.path)")
            debugLog("Found via login shell: \(path.path)")
            binarySourceDescription = "login shell PATH (\(path.path))"
            return path
        }

        // Strategy 3: Hardcoded fallback paths
        let fallbackPaths = [
            "/opt/homebrew/bin/opencode", // Apple Silicon Homebrew
            "/usr/local/bin/opencode", // Intel Homebrew
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path, // OpenCode default
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path, // pip/pipx
            "/usr/bin/opencode" // System-wide
        ]

        for path in fallbackPaths where FileManager.default.fileExists(atPath: path) {
            logger.info("OpenCodeZen: Found via fallback path: \(path)")
            debugLog("Found via fallback: \(path)")
            binarySourceDescription = "fallback (\(path))"
            return URL(fileURLWithPath: path)
        }

        logger.error("OpenCodeZen: Binary not found in any location")
        debugLog("Binary not found anywhere")
        return nil
    }

    /// Finds opencode binary using `which` command in current environment.
    private func findBinaryViaWhich() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["opencode"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }

            guard FileManager.default.fileExists(atPath: output) else { return nil }
            return URL(fileURLWithPath: output)
        } catch {
            debugLog("'which opencode' failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Finds opencode binary using login shell to capture user's full PATH.
    /// This is important because GUI apps do not inherit terminal PATH modifications.
    private func findBinaryViaLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "which opencode 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }

            guard FileManager.default.fileExists(atPath: output) else { return nil }
            return URL(fileURLWithPath: output)
        } catch {
            debugLog("Login shell 'which opencode' failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Parsed statistics from `opencode stats`.
    private struct OpenCodeStats {
        let totalCost: Double
        let avgCostPerDay: Double
        let modelCosts: [String: Double]
        let modelMessages: [String: Int]
    }

    private struct ModelUsageStats {
        var cost: Double?
        var messages: Int?
    }

    struct DisplayStatsAdjustment {
        let totalCost: Double
        let avgCostPerDay: Double
        let modelCosts: [String: Double]
        let messages: Int
        let excludedCost: Double
    }

    func fetch() async throws -> ProviderResult {
        guard let binaryPath = opencodePath else {
            logger.error("OpenCode CLI not found in PATH or standard locations")
            throw ProviderError.providerError("OpenCode CLI not found. Install via: brew install opencode, or ensure 'opencode' is in PATH")
        }

        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            logger.error("OpenCode CLI binary not accessible at \(binaryPath.path)")
            throw ProviderError.providerError("OpenCode CLI not accessible at \(binaryPath.path)")
        }

        debugLog("Fetching current stats only (history tracking disabled)")
        let output = try await runOpenCodeStats(days: 7)
        let stats = try parseStats(output)
        let displayStats = Self.adjustStatsForDisplay(
            totalCost: stats.totalCost,
            avgCostPerDay: stats.avgCostPerDay,
            modelCosts: stats.modelCosts,
            modelMessages: stats.modelMessages
        )
        let now = Date()
        if lastAlibabaStatsAttempt.map({ now.timeIntervalSince($0) >= Self.alibabaStatsRefreshInterval }) ?? true {
            lastAlibabaStatsAttempt = now
            do {
                let alibabaOutput = try await runOpenCodeStats(days: 30)
                if Self.hasModelUsageSection(in: alibabaOutput) {
                    cachedAlibabaActivity = Self.parseAlibabaActivity(from: alibabaOutput)
                    AlibabaActivityCache.set(cachedAlibabaActivity)
                    let modelCount = cachedAlibabaActivity.count
                    logger.info("Alibaba local activity updated for \(modelCount) model(s) over 30 days")
                } else {
                    logger.warning("Alibaba local stats output has no MODEL USAGE section; preserving cached activity")
                }
            } catch {
                logger.warning("Alibaba local stats collection failed: \(error.localizedDescription)")
            }
        }

        let monthlyLimit = 1000.0
        let utilization = min((displayStats.totalCost / monthlyLimit) * 100, 100)
        logger.info("OpenCode Zen: $\(String(format: "%.2f", displayStats.totalCost)) (\(String(format: "%.1f", utilization))% of $\(monthlyLimit) limit)")
        if displayStats.excludedCost > 0 {
            let excludedSummary = String(format: "%.2f", displayStats.excludedCost)
            logger.info("OpenCode Zen: Excluded $\(excludedSummary) of non-Zen OpenCode stats usage from pay-as-you-go totals")
            debugLog("Excluded $\(excludedSummary) of non-Zen OpenCode stats usage from OpenCode Zen totals")
        }

        let details = DetailedUsage(
            modelBreakdown: displayStats.modelCosts,
            sessions: nil,
            messages: displayStats.messages > 0 ? displayStats.messages : nil,
            avgCostPerDay: displayStats.avgCostPerDay > 0 ? displayStats.avgCostPerDay : nil,
            monthlyCost: displayStats.totalCost,
            authSource: "opencode CLI via \(binarySourceDescription)"
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: utilization, cost: displayStats.totalCost, resetsAt: nil),
            details: details
        )
    }

    static func parseAlibabaActivity(from output: String) -> [String: AlibabaModelActivity] {
        var result: [String: AlibabaModelActivity] = [:]
        var currentModel: String?
        var inModelSection = false
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: #"\u{001B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("│") else { continue }
            let text = trimmedTableCell(line)
            if isStatsSectionHeader(text) {
                inModelSection = text == "MODEL USAGE"
                currentModel = nil
                continue
            }
            guard inModelSection else { continue }
            if text.hasPrefix("Messages") || text.hasPrefix("Input Tokens") || text.hasPrefix("Output Tokens") || text.hasPrefix("Cache Read") || text.hasPrefix("Cache Write") {
                guard let model = currentModel, model.hasPrefix("alibaba-token-plan/"), let value = tokenCount(in: text) else { continue }
                var stats = result[model] ?? AlibabaModelActivity()
                if text.hasPrefix("Messages") { stats.messages = value }
                else if text.hasPrefix("Input Tokens") { stats.inputTokens = value }
                else if text.hasPrefix("Output Tokens") { stats.outputTokens = value }
                else if text.hasPrefix("Cache Read") { stats.cacheReadTokens = value }
                else { stats.cacheWriteTokens = value }
                result[model] = stats
            } else if !isStatsMetricLine(text) {
                currentModel = text
            }
        }
        return result
    }

    static func hasModelUsageSection(in output: String) -> Bool {
        output.components(separatedBy: .newlines).contains { rawLine in
            let line = rawLine.replacingOccurrences(
                of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("│") && trimmedTableCell(line) == "MODEL USAGE"
        }
    }

    private static func tokenCount(in text: String) -> Int? {
        guard let range = text.range(of: #"[0-9][0-9,.]*\s*[KkMm]?"#, options: .regularExpression) else { return nil }
        let token = String(text[range]).replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let suffix = token.last?.lowercased()
        let numeric = (suffix == "k" || suffix == "m") ? String(token.dropLast()) : token
        guard let value = Double(numeric) else { return nil }
        let multiplier = suffix == "k" ? 1_000.0 : (suffix == "m" ? 1_000_000.0 : 1.0)
        return Int((value * multiplier).rounded())
    }

    private func runOpenCodeStats(days: Int) async throws -> String {
        guard let binaryPath = opencodePath else {
            throw ProviderError.providerError("OpenCode CLI not found")
        }

        // `opencode stats` occasionally hangs and leaves a background process alive
        // forever. Reap any that have outlived a sane lifetime before spawning a new
        // one so these zombies do not pile up across refresh cycles.
        killStaleOpenCodeStatsProcesses()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binaryPath
            // Use the unlimited --models form so filtering can inspect every
            // reported provider/model row instead of truncating the stats table.
            process.arguments = ["stats", "--days", "\(days)", "--models"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // This buffer is only mutated by Process handlers for this process lifecycle.
            nonisolated(unsafe) var outputData = Data()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    outputData.append(data)
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil

                let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    outputData.append(remainingData)
                }

                if proc.terminationStatus != 0 {
                    continuation.resume(throwing: ProviderError.providerError("OpenCode CLI failed with exit code \(proc.terminationStatus)"))
                    return
                }

                guard let output = String(data: outputData, encoding: .utf8) else {
                    continuation.resume(throwing: ProviderError.decodingError("Failed to decode CLI output"))
                    return
                }

                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProviderError.networkError("Failed to execute CLI: \(error.localizedDescription)"))
            }
        }
    }

    /// Kills stale `opencode stats` processes that have run for over an hour.
    ///
    /// A healthy stats invocation finishes in seconds. When the CLI hangs it keeps a
    /// process alive in the background indefinitely, and these accumulate across our
    /// periodic refreshes. We reap anything past the threshold before starting a fresh
    /// run so the hung processes do not leak resources.
    private func killStaleOpenCodeStatsProcesses() {
        // 1 hour. Legitimate runs finish in seconds, so anything older is hung.
        let staleThresholdSeconds = 3600

        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        // `etime` (elapsed wall-clock time), not `etimes`: macOS BSD ps has no `etimes`
        // keyword (that's Linux procps-only) and prints "ps: etimes: keyword not found",
        // silently dropping the column. That shifted every row out from under this
        // pid/etimes/command parse, so the stale-kill logic never actually matched
        // anything. `etime` instead prints `[[dd-]hh:]mm:ss`, parsed by
        // parseETimeSeconds below; command = full argv string.
        listing.arguments = ["-axo", "pid=,etime=,command="]

        let pipe = Pipe()
        listing.standardOutput = pipe
        listing.standardError = FileHandle.nullDevice

        do {
            debugLog("Stale cleanup: listing 'opencode stats' processes")
            try listing.run()
        } catch {
            debugLog("Stale cleanup: failed to list processes: \(error.localizedDescription)")
            return
        }

        // Drain the pipe BEFORE calling waitUntilExit(). `ps -axo` output here runs
        // ~291KB, well past the pipe's 64KB kernel buffer. Calling waitUntilExit()
        // first would block this thread waiting for `ps` to exit while `ps` blocks on
        // write() waiting for buffer space that never frees — a permanent mutual
        // deadlock. readDataToEndOfFile() keeps draining as `ps` writes, so `ps` can
        // always make progress and actually reach EOF.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()

        guard listing.terminationStatus == 0 else {
            debugLog("Stale cleanup: process listing exited with code \(listing.terminationStatus)")
            return
        }

        guard let output = String(data: data, encoding: .utf8) else { return }

        let selfPid = ProcessInfo.processInfo.processIdentifier
        let staleProcesses = Self.staleOpenCodeStatsPIDs(
            fromPSOutput: output,
            staleThresholdSeconds: staleThresholdSeconds,
            selfPid: selfPid
        )

        for (pid, etimeSeconds) in staleProcesses {
            // Hung processes ignore SIGTERM, so SIGKILL guarantees the reap.
            kill(pid, SIGKILL)
            logger.info("OpenCodeZen: Killed stale 'opencode stats' process pid=\(pid) (running \(etimeSeconds)s)")
            debugLog("Killed stale 'opencode stats' pid=\(pid) etime=\(etimeSeconds)s")
        }
    }

    /// Parses BSD `ps -o etime=` elapsed-time format `[[dd-]hh:]mm:ss` into total
    /// seconds. macOS `ps` has no `etimes` (seconds-only) keyword, so the stale-kill
    /// logic must parse this human-readable string itself instead of reading a plain
    /// integer column. Returns nil for anything that doesn't match the format.
    static func parseETimeSeconds(_ field: String) -> Int? {
        guard !field.isEmpty else { return nil }

        // Optional "dd-" day prefix, e.g. "2-03:04:05" for 2 days.
        let dayAndTime = field.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let days: Int
        let timePart: Substring
        if dayAndTime.count == 2 {
            guard let parsedDays = Int(dayAndTime[0]) else { return nil }
            days = parsedDays
            timePart = dayAndTime[1]
        } else {
            days = 0
            timePart = field[...]
        }

        // Remainder is either "mm:ss" or "hh:mm:ss".
        let components = timePart.split(separator: ":")
        let parsedComponents = components.compactMap { Int($0) }
        guard parsedComponents.count == components.count else { return nil }

        let seconds: Int
        switch parsedComponents.count {
        case 2:
            seconds = parsedComponents[0] * 60 + parsedComponents[1]
        case 3:
            seconds = parsedComponents[0] * 3_600 + parsedComponents[1] * 60 + parsedComponents[2]
        default:
            return nil
        }

        return days * 86_400 + seconds
    }

    /// Filters `ps -axo pid=,etime=,command=` output down to (pid, elapsed seconds)
    /// pairs of `opencode stats` invocations that have outlived `staleThresholdSeconds`.
    /// Elapsed seconds ride along so the caller can still log how long each one ran.
    /// Split out of `killStaleOpenCodeStatsProcesses()` as pure string-in/data-out
    /// logic so it is unit-testable without spawning a real `ps` process.
    static func staleOpenCodeStatsPIDs(
        fromPSOutput output: String,
        staleThresholdSeconds: Int,
        selfPid: Int32
    ) -> [(pid: Int32, etimeSeconds: Int)] {
        var staleProcesses: [(pid: Int32, etimeSeconds: Int)] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Split into: pid, etime, command (command keeps its own spaces).
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let etimeSeconds = parseETimeSeconds(String(parts[1])) else { continue }

            let command = String(parts[2])

            guard command.contains("opencode"), command.contains(" stats") else { continue }
            guard etimeSeconds >= staleThresholdSeconds else { continue }
            guard pid != selfPid else { continue }

            staleProcesses.append((pid: pid, etimeSeconds: etimeSeconds))
        }

        return staleProcesses
    }

    static func adjustStatsForDisplay(
        totalCost: Double,
        avgCostPerDay: Double,
        modelCosts: [String: Double],
        modelMessages: [String: Int] = [:]
    ) -> DisplayStatsAdjustment {
        let zenModelCosts = modelCosts.filter { isOpenCodeZenModel($0.key) }
        let zenCost = zenModelCosts
            .reduce(0.0) { partialResult, item in
                partialResult + max(item.value, 0)
            }
        let excludedCost = max(0, totalCost - zenCost)
        let adjustedAvgCostPerDay: Double
        if totalCost > 0, avgCostPerDay > 0 {
            adjustedAvgCostPerDay = max(0, avgCostPerDay * (zenCost / totalCost))
        } else {
            adjustedAvgCostPerDay = 0
        }

        let zenMessages = modelMessages
            .filter { isOpenCodeZenModel($0.key) }
            .reduce(0) { partialResult, item in
                partialResult + max(item.value, 0)
            }

        return DisplayStatsAdjustment(
            totalCost: zenCost,
            avgCostPerDay: adjustedAvgCostPerDay,
            modelCosts: zenModelCosts,
            messages: zenMessages,
            excludedCost: excludedCost
        )
    }

    static func isOpenCodeZenModel(_ modelName: String) -> Bool {
        let normalized = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("opencode/") || normalized.hasPrefix("opencode-go/")
    }

    /// Parses opencode stats output using regex patterns.
    private func parseStats(_ output: String) throws -> OpenCodeStats {
        let totalCostPattern = #"│Total Cost\s+\$([0-9.]+)"#
        guard let totalCostMatch = output.range(of: totalCostPattern, options: .regularExpression) else {
            logger.error("Cannot parse total cost from output")
            throw ProviderError.decodingError("Cannot parse total cost")
        }
        let totalCostStr = String(output[totalCostMatch])
            .replacingOccurrences(of: #"│Total Cost\s+\$"#, with: "", options: .regularExpression)
        guard let totalCost = Double(totalCostStr) else {
            throw ProviderError.decodingError("Invalid total cost value")
        }

        let avgCostPattern = #"│Avg Cost/Day\s+\$([0-9.]+)"#
        guard let avgCostMatch = output.range(of: avgCostPattern, options: .regularExpression) else {
            throw ProviderError.decodingError("Cannot parse avg cost")
        }
        let avgCostStr = String(output[avgCostMatch])
            .replacingOccurrences(of: #"│Avg Cost/Day\s+\$"#, with: "", options: .regularExpression)
        guard let avgCost = Double(avgCostStr) else {
            throw ProviderError.decodingError("Invalid avg cost value")
        }

        let modelCosts = Self.parseModelCosts(from: output)
        let modelMessages = Self.parseModelMessages(from: output)

        return OpenCodeStats(
            totalCost: totalCost,
            avgCostPerDay: avgCost,
            modelCosts: modelCosts,
            modelMessages: modelMessages
        )
    }

    static func parseModelCosts(from output: String) -> [String: Double] {
        parseModelUsageStats(from: output).compactMapValues(\.cost)
    }

    static func parseModelMessages(from output: String) -> [String: Int] {
        parseModelUsageStats(from: output).compactMapValues(\.messages)
    }

    private static func parseModelUsageStats(from output: String) -> [String: ModelUsageStats] {
        var modelUsageStats: [String: ModelUsageStats] = [:]
        var currentModel: String?
        var isInModelUsageSection = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(
                of: #"\u{001B}\[[0-9;]*[A-Za-z]"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            guard line.hasPrefix("│") else {
                if line.hasPrefix("├") || line.hasPrefix("└") {
                    currentModel = nil
                }
                continue
            }

            let text = trimmedTableCell(line)
            guard !text.isEmpty else { continue }

            if isStatsSectionHeader(text) {
                isInModelUsageSection = text == "MODEL USAGE"
                currentModel = nil
                continue
            }

            guard isInModelUsageSection else { continue }

            if text.hasPrefix("Cost") {
                guard let currentModel,
                      let cost = dollarValue(in: text) else { continue }
                var stats = modelUsageStats[currentModel] ?? ModelUsageStats()
                stats.cost = cost
                modelUsageStats[currentModel] = stats
                continue
            }

            if text.hasPrefix("Messages") {
                guard let currentModel,
                      let messages = integerValue(in: text) else { continue }
                var stats = modelUsageStats[currentModel] ?? ModelUsageStats()
                stats.messages = messages
                modelUsageStats[currentModel] = stats
                continue
            }

            if isStatsMetricLine(text) {
                continue
            }

            currentModel = text
        }

        return modelUsageStats
    }

    private static func trimmedTableCell(_ line: String) -> String {
        var content = line
        if content.first == "│" {
            content.removeFirst()
        }
        if let trailingBorder = content.lastIndex(of: "│") {
            content = String(content[..<trailingBorder])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dollarValue(in text: String) -> Double? {
        guard let dollarIndex = text.lastIndex(of: "$") else { return nil }
        let valueStart = text.index(after: dollarIndex)
        let valueText = text[valueStart...]
            .split(separator: " ")
            .first
            .map(String.init)
        return valueText.flatMap(Double.init)
    }

    private static func integerValue(in text: String) -> Int? {
        guard let valueRange = text.range(of: #"[0-9][0-9,]*"#, options: .regularExpression) else {
            return nil
        }
        let valueText = String(text[valueRange]).replacingOccurrences(of: ",", with: "")
        return Int(valueText)
    }

    private static func isStatsMetricLine(_ text: String) -> Bool {
        let metricPrefixes = [
            "Sessions",
            "Messages",
            "Days",
            "Total Cost",
            "Avg Cost/Day",
            "Avg Tokens/Session",
            "Median Tokens/Session",
            "Input",
            "Output",
            "Input Tokens",
            "Output Tokens",
            "Cache Read",
            "Cache Write"
        ]

        return metricPrefixes.contains { text.hasPrefix($0) }
    }

    private static func isStatsSectionHeader(_ text: String) -> Bool {
        let sectionHeaders = [
            "OVERVIEW",
            "COST & TOKENS",
            "MODEL USAGE",
            "TOOL USAGE"
        ]

        return sectionHeaders.contains(text)
    }
}
