import Foundation

// MARK: - Usage Events API Response

/// Response from POST https://cursor.com/api/dashboard/get-filtered-usage-events
struct UsageEventsResponse: Decodable {
    let usageEventsDisplay: [UsageEvent]?
}

struct UsageEvent: Decodable {
    let timestamp: String
    let model: String?
    let kind: String?
    let usageBasedCosts: String?
    let isTokenBasedCall: Bool?
    let tokenUsage: TokenUsage?
    let isChargeable: Bool?

    struct TokenUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheWriteTokens: Int?
        let cacheReadTokens: Int?
        let totalCents: Double?

        var totalTokens: Int {
            (inputTokens ?? 0) + (outputTokens ?? 0) +
            (cacheWriteTokens ?? 0) + (cacheReadTokens ?? 0)
        }
    }

    var costCents: Double {
        tokenUsage?.totalCents ?? 0
    }

    var costDollars: Double {
        costCents / 100.0
    }
}

// MARK: - Legacy Usage API Response (for request counts)

/// Response from GET https://cursor.com/api/usage?user={userId}
struct LegacyUsageResponse: Decodable {
    let models: [String: ModelUsage]
    let startOfMonth: String?

    struct ModelUsage: Decodable {
        let numRequests: Int
        let maxRequestUsage: Int?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var models: [String: ModelUsage] = [:]
        var startOfMonth: String? = nil

        for key in container.allKeys {
            if key.stringValue == "startOfMonth" {
                startOfMonth = try? container.decode(String.self, forKey: key)
            } else {
                if let usage = try? container.decode(ModelUsage.self, forKey: key) {
                    models[key.stringValue] = usage
                }
            }
        }
        self.models = models
        self.startOfMonth = startOfMonth
    }
}

// MARK: - Parsed Display Data

struct PeriodSummary {
    let label: String
    let requests: Int
    let spendDollars: Double
    let tokens: Int
}

struct UsageDisplayData {
    let totalRequests: Int
    let totalSpendDollars: Double
    let totalTokens: Int
    let lineItems: [LineItem]
    let billingPeriodStart: Date
    let today: PeriodSummary
    let last7Days: PeriodSummary
    let last30Days: PeriodSummary

    struct LineItem {
        let modelName: String
        let requestCount: Int
        let costDollars: Double
        let totalTokens: Int
    }
}

// MARK: - Dynamic Coding Key

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
