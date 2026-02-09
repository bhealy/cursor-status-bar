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
                color = .systemRed
            } else if data.totalSpendDollars >= 50 {
                color = .systemYellow
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

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func formatModelName(_ name: String) -> String {
        // Shorten long model names for readability
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

    // MARK: - Menu Construction

    private func buildMenu(data: UsageDisplayData?, error: String?) {
        let menu = NSMenu()

        if let error = error {
            let errorItem = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        if let data = data {
            // Time period summaries
            let periods = [data.today, data.last7Days, data.last30Days]
            for period in periods {
                let spendStr = String(format: "$%.2f", period.spendDollars)
                let header = NSMenuItem(
                    title: "\(period.label): \(spendStr)  (\(period.requests) req, \(formatTokens(period.tokens)) tokens)",
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                menu.addItem(header)
            }

            menu.addItem(NSMenuItem.separator())

            // Billing period section
            let periodLabel = billingPeriodLabel(data.billingPeriodStart)
            let periodItem = NSMenuItem(
                title: "Billing Period (\(periodLabel)): \(String(format: "$%.2f", data.totalSpendDollars))",
                action: nil,
                keyEquivalent: ""
            )
            periodItem.isEnabled = false
            menu.addItem(periodItem)

            if !data.lineItems.isEmpty {
                for item in data.lineItems {
                    let costStr = String(format: "$%.2f", item.costDollars)
                    let displayName = formatModelName(item.modelName)
                    let line = NSMenuItem(
                        title: "  \(displayName): \(item.requestCount) req — \(costStr)",
                        action: nil,
                        keyEquivalent: ""
                    )
                    line.isEnabled = false
                    menu.addItem(line)
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
