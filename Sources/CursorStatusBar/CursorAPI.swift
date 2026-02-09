import Foundation

enum APIError: Error, LocalizedError {
    case httpError(Int, String?)
    case noData
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "HTTP \(code): \(body ?? "no body")"
        case .noData:
            return "No data received"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        }
    }
}

actor CursorAPI {
    private let sessionToken: String
    private let userId: String

    init(sessionToken: String, userId: String) {
        self.sessionToken = sessionToken
        self.userId = userId
    }

    // MARK: - Fetch billing period start from legacy endpoint

    func fetchBillingPeriodStart() async throws -> Date {
        var components = URLComponents(string: "https://cursor.com/api/usage")!
        components.queryItems = [URLQueryItem(name: "user", value: userId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(sessionToken)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        let legacy = try JSONDecoder().decode(LegacyUsageResponse.self, from: data)

        if let startStr = legacy.startOfMonth {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: startStr) {
                return date
            }
        }

        // Fallback: start of current calendar month
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }

    // MARK: - Fetch Usage Events (current API)

    func fetchUsageEvents(from startDate: Date, to endDate: Date, page: Int = 1, pageSize: Int = 1000) async throws -> [UsageEvent] {
        let url = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(&request)

        let body: [String: Any] = [
            "teamId": 0,
            "startDate": String(Int(startDate.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(endDate.timeIntervalSince1970 * 1000)),
            "page": page,
            "pageSize": pageSize
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        let decoded = try JSONDecoder().decode(UsageEventsResponse.self, from: data)
        return decoded.usageEventsDisplay ?? []
    }

    // MARK: - Combined: fetch everything and aggregate

    func fetchDisplayData() async throws -> UsageDisplayData {
        // Get billing period start
        let billingStart = try await fetchBillingPeriodStart()
        let now = Date()
        let cal = Calendar.current

        // Fetch from the earlier of (billing start, 30 days ago)
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now)!
        let fetchStart = min(billingStart, thirtyDaysAgo)

        // Fetch all usage events
        let events = try await fetchUsageEvents(from: fetchStart, to: now)

        // Time boundaries
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now)!

        // Aggregate by model (billing period) and by time buckets
        var byModel: [String: (count: Int, cents: Double, tokens: Int)] = [:]
        var totalCents: Double = 0
        var totalTokens: Int = 0

        var todayCents: Double = 0, todayReqs = 0, todayTokens = 0
        var week7Cents: Double = 0, week7Reqs = 0, week7Tokens = 0
        var days30Cents: Double = 0, days30Reqs = 0, days30Tokens = 0

        for event in events {
            let model = event.model ?? "unknown"
            let cents = event.costCents
            let tokens = event.tokenUsage?.totalTokens ?? 0

            // Parse timestamp (milliseconds since epoch)
            let timestampMs = Double(event.timestamp) ?? 0
            let eventDate = Date(timeIntervalSince1970: timestampMs / 1000.0)

            // Billing period totals (only events within billing period)
            if eventDate >= billingStart {
                totalCents += cents
                totalTokens += tokens

                var entry = byModel[model] ?? (count: 0, cents: 0, tokens: 0)
                entry.count += 1
                entry.cents += cents
                entry.tokens += tokens
                byModel[model] = entry
            }

            // Time bucket aggregation
            if eventDate >= startOfToday {
                todayCents += cents
                todayReqs += 1
                todayTokens += tokens
            }
            if eventDate >= sevenDaysAgo {
                week7Cents += cents
                week7Reqs += 1
                week7Tokens += tokens
            }
            if eventDate >= thirtyDaysAgo {
                days30Cents += cents
                days30Reqs += 1
                days30Tokens += tokens
            }
        }

        // Build line items sorted by cost descending
        let lineItems = byModel.map { (model, data) in
            UsageDisplayData.LineItem(
                modelName: model,
                requestCount: data.count,
                costDollars: data.cents / 100.0,
                totalTokens: data.tokens
            )
        }.sorted { $0.costDollars > $1.costDollars }

        let billingPeriodEventCount = byModel.values.reduce(0) { $0 + $1.count }

        return UsageDisplayData(
            totalRequests: billingPeriodEventCount,
            totalSpendDollars: totalCents / 100.0,
            totalTokens: totalTokens,
            lineItems: lineItems,
            billingPeriodStart: billingStart,
            today: PeriodSummary(
                label: "Today",
                requests: todayReqs,
                spendDollars: todayCents / 100.0,
                tokens: todayTokens
            ),
            last7Days: PeriodSummary(
                label: "Last 7 Days",
                requests: week7Reqs,
                spendDollars: week7Cents / 100.0,
                tokens: week7Tokens
            ),
            last30Days: PeriodSummary(
                label: "Last 30 Days",
                requests: days30Reqs,
                spendDollars: days30Cents / 100.0,
                tokens: days30Tokens
            )
        )
    }

    // MARK: - Private Helpers

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WorkosCursorSessionToken=\(sessionToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw APIError.httpError(http.statusCode, body)
        }
    }
}
