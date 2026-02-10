import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var api: CursorAPI?
    private var lastData: UsageDisplayData?

    private let refreshInterval: TimeInterval = 60

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setTitle("$...")

        // Use an NSMenu with a custom-view item for reliable click handling
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        do {
            let (sessionToken, userId) = try TokenExtractor.extractToken()
            api = CursorAPI(sessionToken: sessionToken, userId: userId)
        } catch {
            NSLog("[CursorStatusBar] Token extraction failed: %@", error.localizedDescription)
            setTitle("$err")
        }

        refreshData()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let content = PanelBuilder.buildContentView(
            data: lastData,
            error: lastData == nil ? "Loading..." : nil,
            onAction: { [weak self] action in
                self?.statusItem.menu?.cancelTracking()
                self?.handleAction(action)
            }
        )

        // Force layout so fittingSize is accurate
        content.layoutSubtreeIfNeeded()
        let fittingSize = content.fittingSize
        let width = max(fittingSize.width + 4, 420)
        let height = fittingSize.height + 4
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let menuItem = NSMenuItem()
        menuItem.view = content
        menu.addItem(menuItem)
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
                }
            } catch {
                NSLog("[CursorStatusBar] API error: %@", "\(error)")
                await MainActor.run {
                    self.setTitle("Cursor: err")
                }
            }
        }
    }

    // MARK: - Status Bar Title

    private func updateStatusBar(data: UsageDisplayData) {
        let todaySpend = String(format: "$%.2f", data.today.spendDollars)

        if let button = statusItem.button {
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            let color: NSColor
            if data.today.spendDollars >= 50 {
                color = NSColor(red: 1.0, green: 0.40, blue: 0.40, alpha: 1.0)
            } else if data.today.spendDollars >= 10 {
                color = NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
            } else {
                color = NSColor(red: 0.40, green: 0.90, blue: 0.55, alpha: 1.0)
            }

            let attributed = NSMutableAttributedString(string: todaySpend, attributes: [
                .font: font,
                .foregroundColor: color
            ])
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

    // MARK: - Actions

    private func handleAction(_ action: String) {
        switch action {
        case "refresh":
            refreshData()
        case "dashboard":
            if let url = URL(string: "https://cursor.com/dashboard?tab=usage") {
                NSWorkspace.shared.open(url)
            }
        case "quit":
            NSApplication.shared.terminate(nil)
        default:
            break
        }
    }
}
