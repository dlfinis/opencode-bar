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
    /// When the freshest bridge credential capture (ALB session cookie) was read.
    let sessionCapturedAt: Date?

    init(
        usedUSD: Double,
        hardLimitUSD: Double,
        remainingUSD: Double,
        usagePercentage: Double,
        updatedAt: Date?,
        tokenExpiresAt: Date? = nil,
        sessionCapturedAt: Date? = nil
    ) {
        self.usedUSD = usedUSD
        self.hardLimitUSD = hardLimitUSD
        self.remainingUSD = remainingUSD
        self.usagePercentage = usagePercentage
        self.updatedAt = updatedAt
        self.tokenExpiresAt = tokenExpiresAt
        self.sessionCapturedAt = sessionCapturedAt
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

    /// The platform ALB session cookie (`AWSVAAuthSessionCookie`) is the actual
    /// short-lived credential (~1h measured; see globai PLAYBOOK). It carries no
    /// client-readable expiry, so the bridge reports when the freshest capture
    /// was taken. A capture older than the measured cookie lifetime means the
    /// browser renewal chain stopped and the session is likely dead.
    static let sessionStaleAgeMinutes = 50

    /// Age of the freshest session capture, or nil when unknown.
    static func sessionAgeLabel(capturedAt: Date?, now: Date = Date()) -> String? {
        guard let capturedAt else { return nil }
        let totalMinutes = max(0, Int(now.timeIntervalSince(capturedAt) / 60))
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let hours = totalHours % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "Session: \(days)d \(hours)h old"
        }
        if totalHours > 0 {
            return "Session: \(totalHours)h \(minutes)m old"
        }
        return "Session: \(minutes)m old"
    }

    /// True when the session capture is older than the measured cookie lifetime.
    static func isSessionStale(capturedAt: Date?, now: Date = Date()) -> Bool {
        guard let capturedAt else { return false }
        return now.timeIntervalSince(capturedAt) >= Double(sessionStaleAgeMinutes) * 60
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
        let capturedAt: String?
    }

    private struct BridgeJWT: Decodable {
        let expiresAt: String?
    }

    private struct BridgeHeartbeat: Decodable {
        let cookieAlive: Bool?
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
        let healthData = try await requestBridgeData(urlString: Self.bridgeHealthURL, timeout: 3)
        let health = try Self.decodeHealthSnapshot(from: healthData)

        // The bridge keeps quota in memory only and measures it on demand
        // (never polled in the background). After a bridge restart /health
        // carries no numbers until one measurement is requested.
        let quota: GlobAIQuotaSnapshot
        if let measured = health.quota {
            quota = measured
        } else {
            quota = try await measureQuotaOnDemand()
        }

        let snapshot = GlobAIQuotaSnapshot(
            usedUSD: quota.usedUSD,
            hardLimitUSD: quota.hardLimitUSD,
            remainingUSD: quota.remainingUSD,
            usagePercentage: quota.usagePercentage,
            updatedAt: quota.updatedAt,
            tokenExpiresAt: health.tokenExpiresAt,
            sessionCapturedAt: health.sessionCapturedAt
        )

        let updatedLabel = snapshot.updatedAtLabel ?? "unknown"
        let tokenLabel = GlobAIQuotaSnapshot.tokenExpiryLabel(expiresAt: snapshot.tokenExpiresAt) ?? "unknown"
        let sessionLabel = GlobAIQuotaSnapshot.sessionAgeLabel(capturedAt: snapshot.sessionCapturedAt) ?? "unknown"
        debugLog("Project quota received: USD \(String(format: "%.2f", quota.usedUSD)) of USD \(String(format: "%.2f", quota.hardLimitUSD)); updated \(updatedLabel); token \(tokenLabel); \(sessionLabel)")

        let details = DetailedUsage(
            monthlyUsage: quota.usagePercentage,
            limit: quota.hardLimitUSD,
            limitRemaining: quota.remainingUSD,
            resetPeriod: quota.updatedAtLabel,
            monthlyCost: quota.usedUSD,
            tokenExpiresAt: snapshot.tokenExpiresAt,
            sessionCapturedAt: snapshot.sessionCapturedAt
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: quota.usagePercentage, cost: quota.usedUSD, resetsAt: nil),
            details: details
        )
    }

    /// The bridge measures quota only when asked (no background polling).
    private func measureQuotaOnDemand() async throws -> GlobAIQuotaSnapshot {
        debugLog("Health has no measured quota yet; requesting on-demand /quota measurement")
        let quotaData = try await requestBridgeData(urlString: Self.bridgeQuotaURL, timeout: 10)
        return try Self.decodeQuotaSnapshot(from: quotaData)
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
    /// bridge has measured it since its last start) plus the session token expiry.
    struct GlobAIHealthSnapshot: Equatable {
        let quota: GlobAIQuotaSnapshot?
        let tokenExpiresAt: Date?
        let sessionCapturedAt: Date?
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
        let sessionCapturedAt = health.credentials.flatMap { Self.parseUpdatedAt($0.capturedAt) }
        let quota = try Self.measuredQuota(from: health.quota)
        return GlobAIHealthSnapshot(quota: quota, tokenExpiresAt: tokenExpiresAt, sessionCapturedAt: sessionCapturedAt)
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
