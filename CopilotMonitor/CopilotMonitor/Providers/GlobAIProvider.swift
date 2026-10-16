import Foundation
import os.log

private let globAILogger = Logger(subsystem: "com.opencodeproviders", category: "GlobAIProvider")

struct GlobAIQuotaSnapshot: Equatable {
    let usedUSD: Double
    let hardLimitUSD: Double
    let remainingUSD: Double
    let usagePercentage: Double
    let updatedAt: Date?

    var updatedAtLabel: String? {
        guard let updatedAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
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
    private static let bridgeConnectionError = "Cannot connect to the local Glob.AI OS bridge at 127.0.0.1:8787. Start it with ~/.agents/globai/bridge.sh start."

    private let dataRequest: DataRequest

    private struct BridgeHealthResponse: Decodable {
        let ok: Bool?
        let heartbeat: BridgeHeartbeat?
        let quota: BridgeQuota?
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

    var fetchTimeout: TimeInterval { 5 }

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
        guard let url = URL(string: Self.bridgeHealthURL) else {
            throw ProviderError.providerError("Invalid local Glob.AI OS bridge URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3

        globAILogger.info("Fetching Glob.AI project quota from the local bridge")
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

        let quota = try Self.decodeQuotaSnapshot(from: data)
        let updatedLabel = quota.updatedAtLabel ?? "unknown"
        debugLog("Project quota received: USD \(String(format: "%.2f", quota.usedUSD)) of USD \(String(format: "%.2f", quota.hardLimitUSD)); updated \(updatedLabel)")

        let details = DetailedUsage(
            monthlyUsage: quota.usagePercentage,
            limit: quota.hardLimitUSD,
            limitRemaining: quota.remainingUSD,
            resetPeriod: quota.updatedAtLabel,
            monthlyCost: quota.usedUSD
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: quota.usagePercentage, cost: quota.usedUSD, resetsAt: nil),
            details: details
        )
    }

    static func decodeQuotaSnapshot(from data: Data) throws -> GlobAIQuotaSnapshot {
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
        guard let quota = health.quota,
              let used = quota.usedUSD,
              let hardLimit = quota.hardLimitUSD else {
            throw ProviderError.networkError("The local Glob.AI OS bridge has not measured project quota yet.")
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
