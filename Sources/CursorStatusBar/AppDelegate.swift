import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var api: CursorAPI?
    private var lastData: UsageDisplayData?

    private let refreshInterval: TimeInterval = 60 // seconds

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only app
        NSApp.setActivationPolicy(.accessory)

        // Create the status bar item with variable width
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set initial loading state
        setTitle("Cursor: ...")

        // Build the initial menu
        buildMenu(data: nil, error: nil)

        // Attempt to initialize the API client
        do {
            let (sessionToken, userId) = try TokenExtractor.extractToken()
            api = CursorAPI(sessionToken: sessionToken, userId: userId)
        } catch {
            print("[CursorStatusBar] Token extraction failed: \(error.localizedDescription)")
            setTitle("Cursor: err")
            buildMenu(data: nil, error: error.localizedDescription)
        }

        // Initial fetch
        refreshData()

        // Start periodic refresh
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    // MARK: - Data Refresh

    private func refreshData() {
        guard let api = api else { return }

        Task {
            do {
                let data = try await api.fetchDisplayData()
                await MainActor.run {
                    self.lastData = data
                    self.updateStatusBar(data: data)
                    self.buildMenu(data: data, error: nil)
                }
            } catch {
                print("[CursorStatusBar] API error: \(error)")
                await MainActor.run {
                    self.setTitle("Cursor: err")
                    self.buildMenu(data: self.lastData, error: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Status Bar Title

    private func updateStatusBar(data: UsageDisplayData) {
        let todaySpend = String(format: "$%.2f", data.today.spendDollars)
        let periodSpend = String(format: "$%.2f", data.totalSpendDollars)
        let title = "Today: \(todaySpend) | Period: \(periodSpend)"

        if let button = statusItem.button {
            let attributed = NSMutableAttributedString(string: title)

            // Color the period spend based on thresholds
            let color: NSColor
            if data.totalSpendDollars >= 100 {
                color = NSColor(red: 1.0, green: 0.55, blue: 0.35, alpha: 1.0) // bright orange
            } else if data.totalSpendDollars >= 50 {
                color = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1.0) // bright yellow
            } else {
                color = .labelColor
            }

            let periodStart = title.count - periodSpend.count
            let periodRange = NSRange(location: periodStart, length: periodSpend.count)
            attributed.addAttribute(.foregroundColor, value: color, range: periodRange)

            // Use a monospaced font for consistent width
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.count))

            button.attributedTitle = attributed
        }
    }

    private func setTitle(_ text: String) {
        if let button = statusItem.button {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            button.attributedTitle = attributed
        }
    }

    // MARK: - Formatting Helpers

    private let menuFont = NSFont.systemFont(ofSize: 13)
    private let menuFontBold = NSFont.boldSystemFont(ofSize: 13)
    private let menuFontSmall = NSFont.systemFont(ofSize: 12)
    private let menuFontMono = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    private func spendColor(_ dollars: Double) -> NSColor {
        if dollars >= 50 { return NSColor(red: 0.75, green: 0.05, blue: 0.05, alpha: 1.0) }      // deep red
        if dollars >= 10 { return NSColor(red: 0.70, green: 0.45, blue: 0.00, alpha: 1.0) }      // dark amber
        if dollars > 0   { return NSColor(red: 0.00, green: 0.50, blue: 0.25, alpha: 1.0) }      // dark green
        return .labelColor
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func formatModelName(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(of: "-high-thinking", with: " (thinking)")
        s = s.replacingOccurrences(of: "-preview", with: "")
        return s
    }

    private func billingPeriodLabel(_ start: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: Date())
        return "\(startStr) – \(endStr)"
    }

    /// Create a disabled menu item with an attributed title (preserves colors)
    private func styledItem(_ attributed: NSAttributedString) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = attributed
        item.isEnabled = false
        return item
    }

    /// Build an attributed string for a section header
    private func headerString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: headerFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ])
    }

    /// Build an attributed string for a period summary line: "Today: $6.78  (9 req, 6.4M tokens)"
    private func periodString(_ period: PeriodSummary) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Label
        result.append(NSAttributedString(string: "\(period.label):  ", attributes: [
            .font: menuFontBold,
            .foregroundColor: NSColor.labelColor
        ]))

        // Spend amount (colored, bold)
        let spendStr = String(format: "$%.2f", period.spendDollars)
        result.append(NSAttributedString(string: spendStr, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: spendColor(period.spendDollars)
        ]))

        // Details
        let details = "   \(period.requests) req  ·  \(formatTokens(period.tokens)) tokens"
        result.append(NSAttributedString(string: details, attributes: [
            .font: menuFontSmall,
            .foregroundColor: NSColor.labelColor
        ]))

        return result
    }

    /// Build an attributed string for a model line item
    private func modelItemString(name: String, requests: Int, cost: Double) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let displayName = formatModelName(name)
        result.append(NSAttributedString(string: "  \(displayName)  ", attributes: [
            .font: menuFontSmall,
            .foregroundColor: NSColor.labelColor
        ]))

        result.append(NSAttributedString(string: "\(requests) req", attributes: [
            .font: menuFontSmall,
            .foregroundColor: NSColor.labelColor
        ]))

        let costStr = String(format: "  $%.2f", cost)
        result.append(NSAttributedString(string: costStr, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: spendColor(cost)
        ]))

        return result
    }

    // MARK: - Menu Construction

    private func buildMenu(data: UsageDisplayData?, error: String?) {
        let menu = NSMenu()

        if let error = error {
            let errStr = NSAttributedString(string: "  \(error)", attributes: [
                .font: menuFontSmall,
                .foregroundColor: NSColor.systemRed
            ])
            menu.addItem(styledItem(errStr))
            menu.addItem(NSMenuItem.separator())
        }

        if let data = data {
            // Time period summaries
            menu.addItem(styledItem(headerString("SPENDING")))
            menu.addItem(styledItem(periodString(data.today)))
            menu.addItem(styledItem(periodString(data.last7Days)))
            menu.addItem(styledItem(periodString(data.last30Days)))

            menu.addItem(NSMenuItem.separator())

            // Billing period section
            let periodLabel = billingPeriodLabel(data.billingPeriodStart)
            let billingHeader = NSMutableAttributedString()
            billingHeader.append(NSAttributedString(string: "BILLING PERIOD", attributes: [
                .font: headerFont,
                .foregroundColor: NSColor.tertiaryLabelColor
            ]))
            billingHeader.append(NSAttributedString(string: "  \(periodLabel)  ", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]))
            let totalStr = String(format: "$%.2f", data.totalSpendDollars)
            billingHeader.append(NSAttributedString(string: totalStr, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: spendColor(data.totalSpendDollars)
            ]))
            menu.addItem(styledItem(billingHeader))

            if !data.lineItems.isEmpty {
                for item in data.lineItems {
                    menu.addItem(styledItem(modelItemString(
                        name: item.modelName,
                        requests: item.requestCount,
                        cost: item.costDollars
                    )))
                }
            }

            menu.addItem(NSMenuItem.separator())
        }

        // Action items
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let dashboardItem = NSMenuItem(title: "Open Cursor Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Menu Actions

    @objc private func refreshClicked() {
        refreshData()
    }

    @objc private func openDashboard() {
        if let url = URL(string: "https://cursor.com/dashboard?tab=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
