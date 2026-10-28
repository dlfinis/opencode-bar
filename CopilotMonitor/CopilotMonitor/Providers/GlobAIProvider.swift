import Foundation
import os.log

private let globAILogger = Logger(subsystem: "com.opencodeproviders", category: "GlobAIProvider")

struct GlobAIQuotaSnapshot: Equatable {
    let usedUSD: Double
    let hardLimitUSD: Double
    let remainingUSD: Double
    let usagePercentage: Double
    let updatedAt: Date?
    let tokenExpiresAt: Date?
    /// When the bridge last verified the platform session (result of the most
    /// recent platform call, conversation or quota measurement alike).
    let sessionVerifiedAt: Date?

    init(
        usedUSD: Double,
        hardLimitUSD: Double,
        remainingUSD: Double,
        usagePercentage: Double,
        updatedAt: Date?,
        tokenExpiresAt: Date? = nil,
        sessionVerifiedAt: Date? = nil
    ) {
        self.usedUSD = usedUSD
        self.hardLimitUSD = hardLimitUSD
        self.remainingUSD = remainingUSD
        self.usagePercentage = usagePercentage
        self.updatedAt = updatedAt
        self.tokenExpiresAt = tokenExpiresAt
        self.sessionVerifiedAt = sessionVerifiedAt
    }

    var updatedAtLabel: String? {
        guard let updatedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }

    /// Human label for the bridge Bearer JWT expiry (24h lifetime).
    /// Returns nil when the expiry is unknown, "Bearer expired" once in the past.
    static func tokenExpiryLabel(expiresAt: Date?, now: Date = Date()) -> String? {
        guard let tokenExpiresAt = expiresAt else { return nil }
        let remaining = Int(tokenExpiresAt.timeIntervalSince(now))
        if remaining <= 0 { return "Bearer expired" }

        let totalMinutes = remaining / 60
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let hours = totalHours % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "Bearer expires in \(days)d \(hours)h"
        }
        if totalHours > 0 {
            return "Bearer expires in \(totalHours)h"
        }
        return "Bearer expires in \(minutes)m"
    }

    /// When the bridge last verified the platform session. Any platform call
    /// (conversation or quota measurement) records the outcome, so this is the
    /// last moment the session was known to work. Nil means the bridge never
    /// called the platform since it started.
    static func sessionVerifiedLabel(verifiedAt: Date?, now: Date = Date()) -> String {
        guard let verifiedAt else { return "Session: not verified yet" }
        let totalMinutes = max(0, Int(now.timeIntervalSince(verifiedAt) / 60))
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let hours = totalHours % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "Session: verified \(days)d \(hours)h ago"
        }
        if totalHours > 0 {
            return "Session: verified \(totalHours)h \(minutes)m ago"
        }
        return "Session: verified \(minutes)m ago"
    }

    static func warningLevel(used: Double, limit: Double) -> Int? {
        guard used.isFinite, used >= 0,
              limit.isFinite, limit > 0 else {
            return nil
        }

        let usageRatio = used / limit
        if usageRatio >= 0.90 {
            return 90
        }
        if usageRatio >= 0.75 {
            return 75
        }
        return nil
    }
}

final class GlobAIProvider: ProviderProtocol {
    typealias DataRequest = (URLRequest) async throws -> (Data, URLResponse)

    let identifier: ProviderIdentifier = .globAI
    let type: ProviderType = .payAsYouGo
    let allowsCachedResultOnFetchFailure = true

    private static let bridgeHealthURL = "http://127.0.0.1:8787/health"
    private static let bridgeQuotaURL = "http://127.0.0.1:8787/quota"
    private static let bridgeConnectionError = "Cannot connect to the local Glob.AI OS bridge at 127.0.0.1:8787. Start it with ~/.agents/globai/bridge.sh start."

    private let dataRequest: DataRequest

    private struct BridgeHealthResponse: Decodable {
        let ok: Bool?
        let credentials: BridgeCredentials?
        let heartbeat: BridgeHeartbeat?
        let quota: BridgeQuota?
    }

    private struct BridgeCredentials: Decodable {
        let jwt: BridgeJWT?
    }

    private struct BridgeJWT: Decodable {
        let expiresAt: String?
    }

    private struct BridgeHeartbeat: Decodable {
        let cookieAlive: Bool?
        let lastBeat: String?
    }

    private struct BridgeQuota: Decodable {
        let usedUSD: Double?
        let hardLimitUSD: Double?
        let remainingUSD: Double?
        let usagePercentage: Double?
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case usedUSD = "usedUsd"
            case hardLimitUSD = "hardLimitUsd"
            case remainingUSD = "remainingUsd"
            case usagePercentage = "pct"
            case updatedAt
        }
    }

    init(
        dataRequest: @escaping DataRequest = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.dataRequest = dataRequest
    }

    var fetchTimeout: TimeInterval { 12 }

    func shouldPauseAutomaticRefresh(after error: Error) -> Bool {
        guard let providerError = error as? ProviderError,
              case .networkError = providerError else {
            return false
        }
        return true
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        let line = "[\(Date())] GlobAIProvider: \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let path = "/tmp/provider_debug.log"
        if FileManager.default.fileExists(atPath: path),
           let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        #endif
    }

    func fetch() async throws -> ProviderResult {
        // /health carries the session heartbeat and JWT expiry; /quota measures
        // the project quota live. Requesting /quota on every refresh also
        // verifies the platform session, so the heartbeat stays current.
        async let healthData = requestBridgeData(urlString: Self.bridgeHealthURL, timeout: 3)
        async let quotaData = requestBridgeData(urlString: Self.bridgeQuotaURL, timeout: 10)

        let health = try await Self.decodeHealthSnapshot(from: healthData)
        let quota = try await Self.decodeQuotaSnapshot(from: quotaData)

        let snapshot = GlobAIQuotaSnapshot(
            usedUSD: quota.usedUSD,
            hardLimitUSD: quota.hardLimitUSD,
            remainingUSD: quota.remainingUSD,
            usagePercentage: quota.usagePercentage,
            updatedAt: quota.updatedAt,
            tokenExpiresAt: health.tokenExpiresAt,
            sessionVerifiedAt: health.sessionVerifiedAt
        )

        let updatedLabel = snapshot.updatedAtLabel ?? "unknown"
        let tokenLabel = GlobAIQuotaSnapshot.tokenExpiryLabel(expiresAt: snapshot.tokenExpiresAt) ?? "unknown"
        let sessionLabel = GlobAIQuotaSnapshot.sessionVerifiedLabel(verifiedAt: snapshot.sessionVerifiedAt)
        debugLog("Project quota received: USD \(String(format: "%.2f", quota.usedUSD)) of USD \(String(format: "%.2f", quota.hardLimitUSD)); updated \(updatedLabel); token \(tokenLabel); \(sessionLabel)")

        let details = DetailedUsage(
            monthlyUsage: quota.usagePercentage,
            limit: quota.hardLimitUSD,
            limitRemaining: quota.remainingUSD,
            resetPeriod: quota.updatedAtLabel,
            monthlyCost: quota.usedUSD,
            tokenExpiresAt: snapshot.tokenExpiresAt,
            sessionVerifiedAt: snapshot.sessionVerifiedAt
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: quota.usagePercentage, cost: quota.usedUSD, resetsAt: nil),
            details: details
        )
    }

    private func requestBridgeData(urlString: String, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw ProviderError.providerError("Invalid local Glob.AI OS bridge URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        globAILogger.info("Requesting \(url.path, privacy: .public) from the local Glob.AI OS bridge")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await dataRequest(request)
        } catch {
            throw ProviderError.networkError(Self.bridgeConnectionError)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("The local Glob.AI OS bridge returned an invalid response.")
        }

        guard httpResponse.statusCode == 200 else {
            throw ProviderError.networkError("The local Glob.AI OS bridge returned HTTP \(httpResponse.statusCode).")
        }

        return data
    }

    /// Decoded bridge health: the measured quota when available (nil until the
    /// bridge has measured it since its last start), the session token expiry
    /// and the last platform-session verification time.
    struct GlobAIHealthSnapshot: Equatable {
        let quota: GlobAIQuotaSnapshot?
        let tokenExpiresAt: Date?
        let sessionVerifiedAt: Date?
    }

    static func decodeHealthSnapshot(from data: Data) throws -> GlobAIHealthSnapshot {
        let health: BridgeHealthResponse
        do {
            health = try JSONDecoder().decode(BridgeHealthResponse.self, from: data)
        } catch {
            throw ProviderError.decodingError("The Glob.AI OS bridge health response is invalid.")
        }

        guard health.ok == true else {
            throw ProviderError.networkError("The local Glob.AI OS bridge reports that it is unavailable.")
        }
        guard health.heartbeat?.cookieAlive != false else {
            throw ProviderError.networkError("The Glob.AI OS session is disconnected. Restore the bridge session, then select Refresh.")
        }

        let tokenExpiresAt = health.credentials?.jwt.flatMap { Self.parseUpdatedAt($0.expiresAt) }
        let sessionVerifiedAt = health.heartbeat.flatMap { Self.parseUpdatedAt($0.lastBeat) }
        let quota = try Self.measuredQuota(from: health.quota)
        return GlobAIHealthSnapshot(quota: quota, tokenExpiresAt: tokenExpiresAt, sessionVerifiedAt: sessionVerifiedAt)
    }

    /// Decodes a bridge payload that must contain measured quota numbers
    /// (either /health after a measurement or the on-demand /quota response).
    static func decodeQuotaSnapshot(from data: Data) throws -> GlobAIQuotaSnapshot {
        let health = try Self.decodeHealthSnapshot(from: data)
        guard let quota = health.quota else {
            throw ProviderError.networkError("The local Glob.AI OS bridge has not measured project quota yet.")
        }
        return quota
    }

    private static func measuredQuota(from quota: BridgeQuota?) throws -> GlobAIQuotaSnapshot? {
        guard let quota,
              let used = quota.usedUSD,
              let hardLimit = quota.hardLimitUSD else {
            return nil
        }

        guard used.isFinite, used >= 0,
              hardLimit.isFinite, hardLimit > 0 else {
            throw ProviderError.decodingError("Glob.AI project quota contains invalid USD amounts.")
        }

        let remaining = quota.remainingUSD ?? (hardLimit - used)
        let percentage = quota.usagePercentage ?? (used / hardLimit * 100)
        guard remaining.isFinite, percentage.isFinite, percentage >= 0 else {
            throw ProviderError.decodingError("Glob.AI project quota contains invalid remaining or percentage values.")
        }

        return GlobAIQuotaSnapshot(
            usedUSD: used,
            hardLimitUSD: hardLimit,
            remainingUSD: remaining,
            usagePercentage: percentage,
            updatedAt: Self.parseUpdatedAt(quota.updatedAt)
        )
    }

    private static func parseUpdatedAt(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
