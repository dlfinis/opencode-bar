import Foundation
import XCTest
@testable import OpenCode_Bar

final class GlobAIProviderTests: XCTestCase {
    func testFetchReadsProjectQuotaFromLocalBridgeWithoutAPIKey() async throws {
        let provider = GlobAIProvider(dataRequest: { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "127.0.0.1")
            XCTAssertEqual(url.port, 8787)
            XCTAssertEqual(url.path, "/health")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Self.quotaResponse(used: 0.0125), response)
        })

        let result = try await provider.fetch()

        XCTAssertEqual(provider.identifier, .globAI)
        XCTAssertEqual(provider.type, .payAsYouGo)
        XCTAssertEqual(result.usage.cost ?? -1, 0.0125, accuracy: 0.000000001)
        XCTAssertEqual(result.usage.usagePercentage, 0.025, accuracy: 0.000001)
        XCTAssertEqual(result.details?.monthlyCost ?? -1, 0.0125, accuracy: 0.000000001)
        XCTAssertEqual(result.details?.limit ?? -1, 50, accuracy: 0.000000001)
        XCTAssertEqual(result.details?.limitRemaining ?? -1, 49.9875, accuracy: 0.000000001)
        XCTAssertNotNil(result.details?.resetPeriod)
    }

    func testMissingBridgeQuotaIsClassifiedAsConnectionFailure() throws {
        let data = Data(#"{"ok":true,"quota":{"status":"not yet measured"}}"#.utf8)

        XCTAssertThrowsError(try GlobAIProvider.decodeQuotaSnapshot(from: data)) { error in
            guard let providerError = error as? ProviderError,
                  case .networkError = providerError else {
                XCTFail("Expected a network error, got \(error)")
                return
            }
        }
    }

    func testExpiredBridgeSessionIsDetectedAsConnectionFailure() {
        let data = Data(
            #"{"ok":true,"heartbeat":{"cookieAlive":false},"quota":{"usedUsd":1,"hardLimitUsd":50,"remainingUsd":49,"pct":2,"updatedAt":"2026-10-16T12:34:56Z"}}"#.utf8
        )

        XCTAssertThrowsError(try GlobAIProvider.decodeQuotaSnapshot(from: data)) { error in
            guard let providerError = error as? ProviderError,
                  case .networkError = providerError else {
                XCTFail("Expected a network error, got \(error)")
                return
            }
            XCTAssertTrue(GlobAIProvider().shouldPauseAutomaticRefresh(after: providerError))
        }
    }

    func testFetchClassifiesUnauthorizedAndServerResponses() async throws {
        let unauthorizedError = await fetchError(statusCode: 401)
        guard let unauthorizedProviderError = unauthorizedError as? ProviderError,
              case .networkError = unauthorizedProviderError else {
            XCTFail("Expected a connection error for HTTP 401")
            return
        }

        let serverError = await fetchError(statusCode: 503)
        guard let serverProviderError = serverError as? ProviderError,
              case .networkError = serverProviderError else {
            XCTFail("Expected a network error for HTTP 503")
            return
        }
    }

    func testProviderManagerPreservesGlobAIQuotaAndWaitsForManualRefreshAfterFailure() async throws {
        XCTAssertTrue(OpenRouterProvider().allowsCachedResultOnFetchFailure)
        XCTAssertTrue(GlobAIProvider().allowsCachedResultOnFetchFailure)

        let statusSequence = ResponseStatusSequence([200, 503, 200])
        let provider = GlobAIProvider(dataRequest: { request in
            let url = try XCTUnwrap(request.url)
            let statusCode = statusSequence.next()
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Self.quotaResponse(used: 0.0125), response)
        })
        let manager = ProviderManager(providers: [provider])

        let initialFetch = await manager.fetchAll()
        XCTAssertEqual(initialFetch.results[.globAI]?.usage.cost ?? -1, 0.0125, accuracy: 0.000000001)

        let failedFetch = await manager.fetchAll()
        XCTAssertEqual(failedFetch.results[.globAI]?.usage.cost ?? -1, 0.0125, accuracy: 0.000000001)
        XCTAssertTrue(failedFetch.errors[.globAI]?.contains("HTTP 503") == true)
        XCTAssertTrue(failedFetch.errors[.globAI]?.contains("paused until you select Refresh") == true)

        let automaticFetch = await manager.fetchAll()
        XCTAssertEqual(automaticFetch.results[.globAI]?.usage.cost ?? -1, 0.0125, accuracy: 0.000000001)
        XCTAssertTrue(automaticFetch.errors[.globAI]?.contains("paused until you select Refresh") == true)
        XCTAssertEqual(statusSequence.requestCount(), 2)

        let manualRefresh = await manager.fetchAll(forceRefreshProviderIdentifiers: [.globAI])
        XCTAssertEqual(manualRefresh.results[.globAI]?.usage.cost ?? -1, 0.0125, accuracy: 0.000000001)
        XCTAssertNil(manualRefresh.errors[.globAI])
        XCTAssertEqual(statusSequence.requestCount(), 3)
    }

    func testDecodeReadsTheBridgeQuotaAndRejectsInvalidAmounts() throws {
        let snapshot = try GlobAIProvider.decodeQuotaSnapshot(from: Self.quotaResponse(used: 12.5))
        XCTAssertEqual(snapshot.usedUSD, 12.5, accuracy: 0.000001)
        XCTAssertEqual(snapshot.hardLimitUSD, 50, accuracy: 0.000001)
        XCTAssertEqual(snapshot.remainingUSD, 37.5, accuracy: 0.000001)
        XCTAssertEqual(snapshot.usagePercentage, 25, accuracy: 0.000001)

        XCTAssertThrowsError(try GlobAIProvider.decodeQuotaSnapshot(
            from: Data(#"{"ok":true,"quota":{"usedUsd":-1,"hardLimitUsd":50,"remainingUsd":51,"pct":-2}}"#.utf8)
        ))
        XCTAssertThrowsError(try GlobAIProvider.decodeQuotaSnapshot(
            from: Data(#"{"ok":true,"quota":{"usedUsd":1,"hardLimitUsd":0,"remainingUsd":-1,"pct":50}}"#.utf8)
        ))
    }

    func testQuotaWarningsUseSeventyFiveAndNinetyPercentOfActualLimit() {
        XCTAssertNil(GlobAIQuotaSnapshot.warningLevel(used: 37.49, limit: 50))
        XCTAssertEqual(GlobAIQuotaSnapshot.warningLevel(used: 37.50, limit: 50), 75)
        XCTAssertEqual(GlobAIQuotaSnapshot.warningLevel(used: 44.99, limit: 50), 75)
        XCTAssertEqual(GlobAIQuotaSnapshot.warningLevel(used: 45.00, limit: 50), 90)
        XCTAssertNil(GlobAIQuotaSnapshot.warningLevel(used: -.infinity, limit: 50))
        XCTAssertNil(GlobAIQuotaSnapshot.warningLevel(used: 1, limit: .nan))
    }

    private func fetchError(statusCode: Int) async -> Error? {
        let provider = GlobAIProvider(dataRequest: { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Self.quotaResponse(used: 1), response)
        })

        do {
            _ = try await provider.fetch()
            return nil
        } catch {
            return error
        }
    }

    private static func quotaResponse(used: Double) -> Data {
        let remaining = 50 - used
        let percentage = used / 50 * 100
        return Data(
            """
            {"ok":true,"heartbeat":{"cookieAlive":true},"quota":{"usedUsd":\(used),"hardLimitUsd":50,"remainingUsd":\(remaining),"pct":\(percentage),"updatedAt":"2026-10-16T12:34:56.789Z"}}
            """.utf8
        )
    }
}

private final class ResponseStatusSequence {
    private let lock = NSLock()
    private var statusCodes: [Int]
    private var totalRequests = 0

    init(_ statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        totalRequests += 1
        guard !statusCodes.isEmpty else { return 503 }
        return statusCodes.removeFirst()
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return totalRequests
    }
}
