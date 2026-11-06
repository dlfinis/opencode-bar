import Foundation
import XCTest
@testable import OpenCode_Bar

final class MistralProviderTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override static func canInit(with request: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeProvider(
        budgetStatusCode: Int = 200,
        budgetBody: String,
        subscriptionStatusCode: Int = 200,
        subscriptionBody: String = #"{"plan_name":"Pro"}"#,
        userInfoStatusCode: Int = 200,
        userInfoBody: String = #"{"id":"user-1","email":"dev@example.com"}"#
    ) -> MistralProvider {
        let provider = MistralProvider(
            tokenManager: .shared,
            session: makeSession(),
            apiKey: "sk-test-mistral"
        )

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test-mistral")

            let statusCode: Int
            let body: String
            switch url.absoluteString {
            case "https://api.mistral.ai/v1/billing/budget":
                statusCode = budgetStatusCode
                body = budgetBody
            case "https://api.mistral.ai/v1/billing/subscription":
                statusCode = subscriptionStatusCode
                body = subscriptionBody
            case "https://api.mistral.ai/v1/users/me":
                statusCode = userInfoStatusCode
                body = userInfoBody
            default:
                XCTFail("Unexpected Mistral endpoint: \(url.absoluteString)")
                statusCode = 500
                body = ""
            }

            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data(body.utf8))
        }

        return provider
    }

    private let budgetJSON = #"""
    {
      "api_budget": {
        "usage_percentage": 42.5,
        "initial_budget": 300,
        "currency": "EUR",
        "reset_at": "2026-08-01T00:00:00Z"
      },
      "vibe_budget": {
        "usage_percentage": 10,
        "initial_budget": 100,
        "currency": "EUR",
        "reset_at": "2026-09-01T00:00:00Z"
      }
    }
    """#

    func testProviderIdentifierIsMistral() {
        XCTAssertEqual(MistralProvider().identifier, .mistral)
    }

    func testProviderTypeIsQuotaBased() {
        XCTAssertEqual(MistralProvider().type, .quotaBased)
    }

    func testFetchReturnsQuotaAndBudgetDetails() async throws {
        let result = try await makeProvider(budgetBody: budgetJSON).fetch()

        guard case .quotaBased(let remaining, let entitlement, _) = result.usage else {
            return XCTFail("Expected quota-based usage")
        }
        // The Vibe budget is the primary quota, so the reported remaining
        // percentage comes from it (10% used -> 90% remaining).
        XCTAssertEqual(remaining, 90)
        XCTAssertEqual(entitlement, 100)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.mistralPrimaryBudgetLabel, "Vibe Budget")
        XCTAssertEqual(details.monthlyUsage, 10)
        XCTAssertEqual(details.limit, 100)
        XCTAssertEqual(details.limitRemaining, 90)
        XCTAssertEqual(details.balanceCurrency, "EUR")
        XCTAssertEqual(details.secondaryUsage, 42.5)
        XCTAssertEqual(details.mistralAPIBudgetLimit, 300)
        XCTAssertNotNil(details.primaryReset)
        XCTAssertNotNil(details.secondaryReset)
    }

    func testFetchAcceptsNumericStrings() async throws {
        let stringAmountsJSON = #"""
        {
          "api_budget": {
            "usage_percentage": "42.5",
            "initial_budget": "300",
            "currency": "EUR"
          }
        }
        """#

        let result = try await makeProvider(budgetBody: stringAmountsJSON).fetch()
        let details = try XCTUnwrap(result.details)

        XCTAssertEqual(details.monthlyUsage, 127.5)
        XCTAssertEqual(details.limit, 300)
        XCTAssertEqual(details.mistralPrimaryBudgetLabel, "API Budget")
        XCTAssertNil(details.secondaryUsage)
    }

    func testFetchFallsBackToAPIBudgetWhenVibeBudgetIsMissing() async throws {
        let response = #"{"api_budget":{"usage_percentage":25,"initial_budget":40,"currency":"USD"}}"#
        let result = try await makeProvider(budgetBody: response).fetch()

        guard case .quotaBased(let remaining, _, _) = result.usage else {
            return XCTFail("Expected quota-based usage")
        }
        XCTAssertEqual(remaining, 75)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.mistralPrimaryBudgetLabel, "API Budget")
        XCTAssertEqual(details.limit, 40)
        XCTAssertNil(details.secondaryUsage)
    }

    func testFetchMapsHTTP401ToAuthenticationFailure() async throws {
        try await assertAuthenticationFailure(statusCode: 401)
    }

    func testFetchMapsHTTP403ToAuthenticationFailure() async throws {
        try await assertAuthenticationFailure(statusCode: 403)
    }

    func testFetchRejectsBudgetResponseWithoutAnyBudget() async throws {
        let response = #"{"usage_percentage":10,"initial_budget":100}"#
        let provider = makeProvider(budgetBody: response)

        do {
            _ = try await provider.fetch()
            XCTFail("Expected decodingError when both budgets are missing")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("Expected decodingError, got \(error)")
            }
        }
    }

    func testSubscriptionFailureDoesNotDiscardBudgetResult() async throws {
        let result = try await makeProvider(
            budgetBody: budgetJSON,
            subscriptionStatusCode: 500,
            subscriptionBody: ""
        ).fetch()

        XCTAssertNotNil(result.details)
        XCTAssertNil(result.details?.planType)
    }

    func testFetchPopulatesAccountEmail() async throws {
        let result = try await makeProvider(budgetBody: budgetJSON).fetch()

        XCTAssertEqual(result.details?.email, "dev@example.com")
    }

    func testUserInfoFailureDoesNotDiscardBudgetResult() async throws {
        let result = try await makeProvider(
            budgetBody: budgetJSON,
            userInfoStatusCode: 500,
            userInfoBody: ""
        ).fetch()

        XCTAssertNotNil(result.details)
        XCTAssertNil(result.details?.email)
        XCTAssertEqual(result.details?.limit, 100)
    }

    private func assertAuthenticationFailure(statusCode: Int) async throws {
        do {
            _ = try await makeProvider(budgetStatusCode: statusCode, budgetBody: budgetJSON).fetch()
            XCTFail("Expected authenticationFailed for HTTP \(statusCode)")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }
    }
}
