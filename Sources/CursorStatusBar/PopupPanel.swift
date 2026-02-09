import AppKit
import Foundation

/// A custom dark popup panel that appears below the status bar item.
class PopupPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
    }

    /// Close when user clicks outside
    override func resignKey() {
        super.resignKey()
        close()
    }

    override var canBecomeKey: Bool { true }
}

/// The content view for the popup with a dark rounded background.
class PopupContentView: NSView {
    private var trackingArea: NSTrackingArea?
    var onAction: ((String) -> Void)?
    private var hoveredButton: NSView?

    private let bg = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.97)
    private let border = NSColor(white: 0.2, alpha: 1.0)

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        bg.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override var isFlipped: Bool { true }
}

// MARK: - Panel Builder

class PanelBuilder {
    // Colors
    private static let textColor = NSColor(white: 0.92, alpha: 1.0)
    private static let dimColor = NSColor(white: 0.50, alpha: 1.0)
    private static let headerColor = NSColor(white: 0.40, alpha: 1.0)
    private static let sepColor = NSColor(white: 0.20, alpha: 1.0)

    private static let mono13bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private static let mono13     = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    private static let mono12     = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private static let mono12bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private static let mono11     = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func spendColor(_ dollars: Double) -> NSColor {
        if dollars >= 50 { return NSColor(red: 1.0, green: 0.40, blue: 0.40, alpha: 1.0) }   // red
        if dollars >= 10 { return NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0) }   // amber
        if dollars > 0   { return NSColor(red: 0.40, green: 0.90, blue: 0.55, alpha: 1.0) }  // green
        return dimColor
    }

    static func formatModelName(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(of: "-high-thinking", with: " (thinking)")
        s = s.replacingOccurrences(of: "-preview", with: "")
        return s
    }

    static func pad(_ str: String, _ width: Int) -> String {
        if str.count >= width { return String(str.prefix(width)) }
        return str + String(repeating: " ", count: width - str.count)
    }

    static func rpad(_ str: String, _ width: Int) -> String {
        if str.count >= width { return str }
        return String(repeating: " ", count: width - str.count) + str
    }

    /// Build the full panel content view for the given data.
    static func buildContentView(data: UsageDisplayData?, error: String?, onAction: @escaping (String) -> Void) -> NSView {
        let container = PopupContentView()
        container.onAction = onAction

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if let error = error {
            stack.addArrangedSubview(label(error, font: mono12, color: .systemRed))
            stack.addArrangedSubview(separator())
        }

        if let data = data {
            // ── Time Period Header ──
            let hdr = attrLabel(
                parts: [
                    (pad("Time Period", 14), mono11, headerColor),
                    (rpad("Spend", 9), mono11, headerColor)
                ]
            )
            stack.addArrangedSubview(hdr)
            addSpacer(stack, 2)

            // Period rows
            let periods = [data.today, data.last7Days, data.last30Days]
            for period in periods {
                let spendStr = String(format: "$%.2f", period.spendDollars)
                let reqStr = "(\(period.requests) req)"
                let row = attrLabel(
                    parts: [
                        (pad(period.label, 14), mono13bold, textColor),
                        (rpad(spendStr, 9), mono13bold, spendColor(period.spendDollars)),
                        (" " + reqStr, mono12, dimColor)
                    ]
                )
                stack.addArrangedSubview(row)
            }

            addSpacer(stack, 4)
            stack.addArrangedSubview(separator())
            addSpacer(stack, 4)

            // ── Billing Period ──
            stack.addArrangedSubview(
                label("Billing Period \u{2014} By Model", font: mono11, color: headerColor)
            )
            addSpacer(stack, 2)

            let items = Array(data.lineItems.prefix(5))
            for item in items {
                let name = formatModelName(item.modelName)
                let reqStr = "\(item.requestCount) req"
                let costStr = String(format: "$%.2f", item.costDollars)

                let row = attrLabel(
                    parts: [
                        ("  " + pad(name, 26), mono12, textColor),
                        (rpad(reqStr, 8) + " \u{2014} ", mono12, dimColor),
                        (costStr, mono12bold, spendColor(item.costDollars))
                    ]
                )
                stack.addArrangedSubview(row)
            }

            addSpacer(stack, 4)
            stack.addArrangedSubview(separator())
            addSpacer(stack, 4)
        }

        // ── Action buttons ──
        stack.addArrangedSubview(actionButton("Refresh Now", tag: "refresh", onAction: onAction))
        stack.addArrangedSubview(actionButton("Open Cursor Dashboard", tag: "dashboard", onAction: onAction))
        addSpacer(stack, 2)
        stack.addArrangedSubview(separator())
        addSpacer(stack, 2)
        stack.addArrangedSubview(actionButton("Quit", tag: "quit", onAction: onAction))
        addSpacer(stack, 4)

        return container
    }

    // MARK: - View helpers

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        return field
    }

    private static func attrLabel(parts: [(String, NSFont, NSColor)]) -> NSTextField {
        let result = NSMutableAttributedString()
        for (text, font, color) in parts {
            result.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color
            ]))
        }
        let field = NSTextField(labelWithAttributedString: result)
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        return field
    }

    private static func separator() -> NSView {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = sepColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        sep.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return sep
    }

    private static func addSpacer(_ stack: NSStackView, _ height: CGFloat) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        stack.addArrangedSubview(spacer)
    }

    private static func actionButton(_ title: String, tag: String, onAction: @escaping (String) -> Void) -> NSView {
        let button = HoverButton(title: title, tag: tag, onAction: onAction)
        return button
    }
}

// MARK: - Hover Button

class HoverButton: NSView {
    private let label: NSTextField
    private let actionTag: String
    private let onAction: (String) -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(title: String, tag: String, onAction: @escaping (String) -> Void) {
        self.actionTag = tag
        self.onAction = onAction

        label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor(white: 0.92, alpha: 1.0)
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false

        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(equalToConstant: 400)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        onAction(actionTag)
    }
}
