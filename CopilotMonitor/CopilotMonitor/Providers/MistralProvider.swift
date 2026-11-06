import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "MistralProvider")

/// Provider for Mistral AI organization budget tracking.
///
/// Mistral exposes the current billing period budget through its public
/// billing API:
/// - `GET /v1/billing/budget` returns the API and Vibe budgets with the
///   consumed percentage, the allocated amount, the currency and the reset
///   timestamp. The Vibe budget is reported as the primary quota because it
///   covers the coding assistant, which is where usage actually accrues; the
///   API budget is kept as the secondary window.
/// - `GET /v1/billing/subscription` returns the plan name and whether
///   pay-as-you-go is enabled.
///
/// Both endpoints authenticate with a public API key sent in the `x-api-key`
/// header. The Admin API (`/v1/admin/usage`) is intentionally not used because
/// it requires an Enterprise admin key.
final class MistralProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .mistral
    let type: ProviderType = .quotaBased

    private let tokenManager: TokenManager
    private let session: URLSession
    private let apiKeyOverride: String?

    private static let budgetEndpoint = "https://api.mistral.ai/v1/billing/budget"
    private static let subscriptionEndpoint = "https://api.mistral.ai/v1/billing/subscription"
    private static let userInfoEndpoint = "https://api.mistral.ai/v1/users/me"

    init(
        tokenManager: TokenManager = .shared,
        session: URLSession = .shared,
        apiKey: String? = nil
    ) {
        self.tokenManager = tokenManager
        self.session = session
        self.apiKeyOverride = apiKey
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        logger.info("Mistral budget fetch started")

        let credential = resolveCredential()
        guard let credential else {
            logger.error("Mistral API key not found")
            throw ProviderError.authenticationFailed("Mistral API key not available")
        }

        let budget = try await fetchBudget(apiKey: credential.key)

        // Vibe is the budget the user actually consumes (coding assistant),
        // while the API budget only covers direct inference calls. Prefer Vibe
        // as the primary quota and keep the API budget as the secondary window.
        let vibeBudget = budget.vibeBudget
        let apiBudget = budget.apiBudget
        guard let primaryBudget = vibeBudget ?? apiBudget else {
            logger.error("Mistral budget response missing both vibe_budget and api_budget")
            throw ProviderError.decodingError("Missing Mistral budgets")
        }
        let secondaryBudget = (vibeBudget != nil && apiBudget != nil) ? apiBudget : nil
        let primaryLabel = vibeBudget != nil ? "Vibe Budget" : "API Budget"

        // The subscription and identity lookups are best-effort: a failure must
        // not discard a valid budget response.
        let subscription = try? await fetchSubscription(apiKey: credential.key)
        let userInfo = try? await fetchUserInfo(apiKey: credential.key)

        let usagePercent = min(max(primaryBudget.usagePercentage, 0), 100)
        let remainingPercent = max(0, Int((100.0 - usagePercent).rounded()))
        let usedAmount = primaryBudget.initialBudget * usagePercent / 100.0
        let remainingAmount = max(0, primaryBudget.initialBudget - usedAmount)

        let paygEnabled = primaryBudget.paygEnabled
            ?? (vibeBudget != nil ? subscription?.vibePaygEnabled : subscription?.paygEnabled)
            ?? false
        let usage = ProviderUsage.quotaBased(
            remaining: remainingPercent,
            entitlement: 100,
            overagePermitted: paygEnabled
        )

        let summaryParts = [
            subscription?.planName.map { "Plan: \($0)" },
            paygEnabled ? "Pay-as-you-go enabled" : "Included budget only"
        ].compactMap { $0 }

        let details = DetailedUsage(
            monthlyUsage: usedAmount,
            limit: primaryBudget.initialBudget,
            limitRemaining: remainingAmount,
            resetPeriod: APIValueParser.formatResetDate(primaryBudget.resetDate),
            secondaryUsage: secondaryBudget.map { min(max($0.usagePercentage, 0), 100) },
            secondaryReset: secondaryBudget?.resetDate,
            primaryReset: primaryBudget.resetDate,
            planType: subscription?.planName,
            // Reused as the display currency for the monetary budget fields.
            balanceCurrency: primaryBudget.currency,
            email: userInfo?.email,
            authSource: credential.source,
            authUsageSummary: summaryParts.joined(separator: " · "),
            mistralPrimaryBudgetLabel: primaryLabel,
            mistralAPIBudgetLimit: secondaryBudget?.initialBudget
        )

        logger.info(
            "Mistral budget fetched: primary=\(primaryLabel, privacy: .public) used=\(usagePercent, privacy: .public)%, budget=\(primaryBudget.initialBudget, privacy: .public) \(primaryBudget.currency ?? "", privacy: .public), api=\(apiBudget?.usagePercentage ?? -1, privacy: .public)%"
        )

        return ProviderResult(usage: usage, details: details)
    }

    // MARK: - Credentials

    private func resolveCredential() -> (key: String, source: String)? {
        if let apiKeyOverride {
            let trimmed = apiKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (trimmed, "Injected API key")
            }
        }
        return tokenManager.getMistralAPIKeyWithSource()
    }

    // MARK: - Networking

    private func fetchBudget(apiKey: String) async throws -> BudgetResponse {
        let data = try await request(urlString: Self.budgetEndpoint, apiKey: apiKey, label: "budget")
        do {
            return try JSONDecoder().decode(BudgetResponse.self, from: data)
        } catch {
            logger.error("Mistral budget response could not be decoded: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid Mistral budget response")
        }
    }

    private func fetchSubscription(apiKey: String) async throws -> SubscriptionResponse {
        let data = try await request(urlString: Self.subscriptionEndpoint, apiKey: apiKey, label: "subscription")
        do {
            return try JSONDecoder().decode(SubscriptionResponse.self, from: data)
        } catch {
            logger.warning("Mistral subscription response could not be decoded: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid Mistral subscription response")
        }
    }

    private func fetchUserInfo(apiKey: String) async throws -> UserInfoResponse {
        let data = try await request(urlString: Self.userInfoEndpoint, apiKey: apiKey, label: "user info")
        do {
            return try JSONDecoder().decode(UserInfoResponse.self, from: data)
        } catch {
            logger.warning("Mistral user info response could not be decoded: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid Mistral user info response")
        }
    }

    private func request(urlString: String, apiKey: String, label: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw ProviderError.networkError("Invalid Mistral \(label) endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid Mistral \(label) response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 401:
            throw ProviderError.authenticationFailed("Invalid Mistral API key")
        case 403:
            throw ProviderError.authenticationFailed(
                "Mistral API key lacks organization usage permission (see_org_inference_usage)"
            )
        case 404:
            throw ProviderError.networkError("Mistral \(label) endpoint is unavailable for this account")
        default:
            throw ProviderError.networkError("Mistral \(label) HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Response models

    struct BudgetResponse: Decodable {
        let apiBudget: BudgetDetail?
        let vibeBudget: BudgetDetail?

        enum CodingKeys: String, CodingKey {
            case apiBudget = "api_budget"
            case vibeBudget = "vibe_budget"
        }
    }

    struct BudgetDetail: Decodable {
        let usagePercentage: Double
        let initialBudget: Double
        let currency: String?
        let resetDate: Date?
        let paygEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case usagePercentage = "usage_percentage"
            case initialBudget = "initial_budget"
            case currency
            case resetDate = "reset_at"
            case paygEnabled = "payg_enabled"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usagePercentage = try container.decodeFlexibleDouble(forKey: .usagePercentage)
            initialBudget = try container.decodeFlexibleDouble(forKey: .initialBudget)
            currency = try container.decodeIfPresent(String.self, forKey: .currency)
            paygEnabled = try container.decodeIfPresent(Bool.self, forKey: .paygEnabled)
            let rawReset = try container.decodeIfPresent(String.self, forKey: .resetDate)
            resetDate = APIValueParser.parseDate(from: rawReset)
        }
    }

    struct SubscriptionResponse: Decodable {
        let planName: String?
        let paygEnabled: Bool?
        let vibePaygEnabled: Bool?
        let enterprise: Bool?

        enum CodingKeys: String, CodingKey {
            case planName = "plan_name"
            case paygEnabled = "payg_enabled"
            case vibePaygEnabled = "vibe_payg_enabled"
            case enterprise
        }
    }

    /// Account identity returned by `GET /v1/users/me`. Only the email is
    /// surfaced today; workspace and organization are decoded for future use.
    struct UserInfoResponse: Decodable {
        struct Workspace: Decodable {
            let id: String?
            let name: String?
        }

        struct Organization: Decodable {
            let id: String?
            let name: String?
        }

        let id: String?
        let email: String?
        let firstName: String?
        let lastName: String?
        let workspace: Workspace?
        let organization: Organization?

        enum CodingKeys: String, CodingKey {
            case id, email, workspace, organization
            case firstName = "first_name"
            case lastName = "last_name"
        }
    }
}

// MARK: - Flexible numeric decoding

private extension KeyedDecodingContainer {
    /// Decodes a required numeric field that the API may send as a number or
    /// as a numeric string.
    func decodeFlexibleDouble(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let raw = try? decode(String.self, forKey: key),
           let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        throw DecodingError.typeMismatch(
            Double.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a number or numeric string for \(key.stringValue)"
            )
        )
    }
}
