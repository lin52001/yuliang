// Compile with -D YULIANG_STANDALONE -D QUOTA_SHELL_TESTING alongside
// Shared/QuotaCard.swift and the standalone app sources. This harness opens
// only its own short-lived AppKit surfaces, uses a temporary store, and never
// starts the collector or reads Codex credentials.
import AppKit
import CoreGraphics
import Foundation
import QuotaCore
import SwiftUI

private struct ShellCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct DesktopShellCheck {
    private static let expectedCardSize = NSSize(width: 344, height: 160)
    private static let expectedCompactSize = NSSize(width: 280, height: 112)
    private static let expectedDuoSize = NSSize(width: 160, height: 160)

    @MainActor
    static func main() {
        do {
            try runChecks()
            print("PASS desktop shell: native background right-click settings without permanent desktop buttons, persistent continuous controls and companion/color persistence callbacks, independent theme/color radio groups and automatic/forced native material states, Codex/Claude source persistence and rendered Token separation, fixed widget-sized card/Duo styles, icon-only menu status, borderless, shared model, free drag/position lock, visible native character picker, independent Token display, light/dark/system appearance, popover lifecycle, stable geometry, desktop level, hide/recall; both collectors stayed paused; compositor color visually verified separately")
            exit(0)
        } catch {
            fputs("FAIL desktop shell: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ShellCheckFailure(description: message) }
    }

    @MainActor
    private static func settle(_ seconds: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    @MainActor
    private static func settleUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { settle(0.05) }
    }

    @MainActor
    private static func descendant(_ view: NSView, identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = descendant(child, identifier: identifier) { return found }
        }
        return nil
    }

    @MainActor
    private static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window, window.isVisible,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { item in
            (item[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber
                && (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
        }
    }

    @MainActor
    @discardableResult
    private static func render(_ view: NSView, named name: String) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ShellCheckFailure(description: "native view could not allocate a render bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["YULIANG_UI_ARTIFACTS"] {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ShellCheckFailure(description: "native render could not produce a PNG")
            }
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(name)
            try png.write(to: target)
            print("Synthetic native render: \(target.path)")
        }
        return bitmap
    }

    @MainActor
    private static func pixelDifference(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) -> Double {
        guard left.pixelsWide == right.pixelsWide && left.pixelsHigh == right.pixelsHigh else { return 1 }
        var changed = 0
        var count = 0
        for y in stride(from: 8, to: left.pixelsHigh - 8, by: 4) {
            for x in stride(from: 8, to: left.pixelsWide - 8, by: 4) {
                guard let a = left.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = right.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
                if delta > 0.12 { changed += 1 }
                count += 1
            }
        }
        return count == 0 ? 0 : Double(changed) / Double(count)
    }

    @MainActor
    private static func luminance(_ bitmap: NSBitmapImageRep) -> Double {
        var total = 0.0
        var count = 0
        for y in stride(from: 24, to: bitmap.pixelsHigh - 24, by: 17) {
            for x in stride(from: 24, to: bitmap.pixelsWide - 24, by: 17) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.9 else { continue }
                total += Double(0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    @MainActor
    private static func checkDuoGeometry() throws {
        // Clockwise cardinal points catch reversed rings, full/empty endpoint
        // discontinuities and sprites that protrude beyond the authored frame.
        let points: [(Double, CGFloat, CGFloat)] = [
            (0, 40, 13.6), (25, 66.4, 40), (50, 40, 66.4), (75, 13.6, 40), (100, 40, 13.6)
        ]
        for (percent, x, y) in points {
            let layout = QuotaDuoGeometry(size: 80, remainingPercent: percent)
            try require(layout.isKnown && layout.progress == percent
                        && abs(layout.markerX - x) < 0.001 && abs(layout.markerY - y) < 0.001,
                        "Duo ring does not place a known percentage on the expected clockwise endpoint")
            let half = layout.avatarSize / 2
            try require(layout.markerX >= half && layout.markerX <= layout.side - half
                        && layout.markerY >= half && layout.markerY <= layout.side - half,
                        "Duo marker bounds can clip the character at a cardinal endpoint")
        }
        let invalidValues: [Double?] = [nil, Double.nan, Double.infinity, -Double.infinity, -1, 100.1]
        for value in invalidValues {
            let layout = QuotaDuoGeometry(size: 80, remainingPercent: value)
            try require(!layout.isKnown && layout.progress == 0
                        && layout.markerX == 40 && layout.markerY == 40,
                        "unknown or invalid quota became a fabricated ring value")
        }
        for size in [CGFloat.nan, .infinity, -.infinity, -10, 0] {
            let layout = QuotaDuoGeometry(size: size, remainingPercent: 25)
            try require(layout.side.isFinite && layout.side >= 64 && layout.ringDiameter.isFinite
                        && layout.markerX.isFinite && layout.markerY.isFinite,
                        "invalid Duo size produced non-finite or unusably small geometry")
        }
    }

    @MainActor
    private static func settingsPanel() throws -> NSPanel {
        guard let panel = StandaloneSettingsPresenter.shellTestPanel else {
            throw ShellCheckFailure(description: "settings trigger did not present its independent panel")
        }
        try require(isOnScreen(panel) && panel.contentView?.bounds.size == NSSize(width: 260, height: 380),
                    "settings panel is not visibly rendered at its independent 260-by-380-point size")
        return panel
    }

    @MainActor
    private static func settingsButton(_ id: String, in panel: NSPanel) throws -> NSButton {
        guard let content = panel.contentView,
              let button = descendant(content, identifier: "yuliang.settings." + id) as? NSButton else {
            throw ShellCheckFailure(description: "settings panel lost its real button: \(id)")
        }
        let title = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = button.font ?? .systemFont(ofSize: 13)
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        try require(title.count >= 2 && title != "…" && title != "..." && textWidth + 2 <= button.bounds.width,
                    "settings button is blank, ellipsized or too narrow to draw its complete title: \(id)")
        try require(!button.isHidden && button.bounds.height >= 28,
                    "settings button has no usable visible hit region: \(id)")
        return button
    }

    @MainActor
    private static func pressSetting(_ id: String, in panel: NSPanel, staysOpen: Bool = true) throws {
        let button = try settingsButton(id, in: panel)
        try require(button.isEnabled, "settings button is unexpectedly disabled: \(id)")
        button.performClick(nil)
        settle(0.15)
        if staysOpen {
            try require(StandaloneSettingsPresenter.shellTestPanel === panel && isOnScreen(panel),
                        "choosing a setting dismissed or replaced the independent panel: \(id)")
        }
    }

    @MainActor
    private static func openSettings(on desktop: NSPanel) throws -> NSPanel {
        guard let content = desktop.contentView,
              let receiver = descendant(content, identifier: "yuliang.widget.contextMenu") as? StandaloneWidgetContextMenu.ContextView else {
            throw ShellCheckFailure(description: "desktop has no native background contextual settings receiver")
        }
        try require(descendant(content, identifier: "yuliang.settings.button") == nil,
                    "desktop retained a permanent settings button instead of its background context menu")
        try require(receiver.bounds.width >= desktop.contentLayoutRect.width - 2
                    && receiver.bounds.height >= desktop.contentLayoutRect.height - 2,
                    "native contextual settings receiver does not cover the whole widget")
        let point = receiver.convert(NSPoint(x: 8, y: 8), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: desktop.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw ShellCheckFailure(description: "could not create this process's own contextual settings event")
        }
        try require(receiver.acceptsFirstMouse(for: event) && receiver.acceptsContextClick(event, at: point),
                    "widget background rejected its native right-click receiver")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            guard let ordinary = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: desktop.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1) else {
                throw ShellCheckFailure(description: "could not create a local ordinary mouse event")
            }
            try require(!receiver.acceptsContextClick(ordinary, at: point),
                        "background context surface intercepted an ordinary tap or drag")
        }
        if let buddy = descendant(content, identifier: "yuliang.buddy.contextMenu") {
            let buddyPoint = buddy.convert(NSPoint(x: buddy.bounds.midX, y: buddy.bounds.midY), to: nil)
            try require(!receiver.acceptsContextClick(event, at: buddyPoint),
                        "background settings intercepted the character's own context interaction")
        }
        let outside = receiver.convert(NSPoint(x: -10, y: -10), to: nil)
        try require(!receiver.acceptsContextClick(event, at: outside),
                    "background settings accepted a click beyond the real widget bounds")
        // Direct delivery to our own NSView, with no global event posting.
        receiver.rightMouseDown(with: event)
        settle(0.2)
        return try settingsPanel()
    }

    @MainActor
    private static func setting(_ path: [String], shell: StandaloneAppDelegate) throws {
        let panel = try openSettings(on: shell.shellTestPanel)
        defer { StandaloneSettingsPresenter.close(); settle(0.2) }
        guard path.count == 2 else { throw ShellCheckFailure(description: "invalid documented setting path") }
        let group: [String: String] = ["小组件样式": "styles", "显示内容": "display", "外观": "appearance", "互动": "interactions"]
        guard let page = group[path[0]] else { throw ShellCheckFailure(description: "unknown setting group") }
        try pressSetting("nav." + page, in: panel)
        let key: String?
        switch page {
        case "styles": key = ["轻巧卡片": "style.card", "Duo 圆环": "style.duo"][path[1]]
        case "display": key = ["日 Token 用量": "display.dailyTokens", "累计 Token 用量": "display.lifetimeTokens", "紧凑模式": "display.compact"][path[1]]
        case "appearance": key = ["跟随系统": "appearance.system", "浅色": "appearance.light", "深色": "appearance.dark"][path[1]]
        default: key = BuddyAction.interactiveActions.first(where: { $0.label == path[1] }).map { "interaction." + $0.rawValue }
        }
        guard let key else { throw ShellCheckFailure(description: "unknown documented setting choice") }
        try pressSetting(key, in: panel)
        try pressSetting("close", in: panel, staysOpen: false)
        try require(StandaloneSettingsPresenter.shellTestPanel == nil && !StandaloneMenuTracking.isActive,
                    "explicit settings close left a visible or retained settings session")
    }

    @MainActor
    private static func checkPersistentSettings(model: StandaloneModel, desktop: NSPanel,
                                               tokens: TokenUsageSnapshot, prefix: String,
                                               capturePages: Bool) throws {
        let records = model.document.records
        let dailyBefore = model.showDailyTokens
        let lifetimeBefore = model.showLifetimeTokens
        let appearanceBefore = model.appearance
        let widgetSize = desktop.frame.size
        let panel = try openSettings(on: desktop)
        defer {
            StandaloneSettingsPresenter.close()
            model.showDailyTokens = dailyBefore
            model.showLifetimeTokens = lifetimeBefore
            model.appearance = appearanceBefore
            model.buddyActivity = nil
            model.now = Date()
            settle(0.3)
        }
        for id in ["sources", "styles", "display", "appearance", "windows", "characters", "interactions", "language"] {
            _ = try settingsButton("nav." + id, in: panel)
        }
        try pressSetting("nav.styles", in: panel)
        let cardChoice = try settingsButton("style.card", in: panel)
        let duoChoice = try settingsButton("style.duo", in: panel)
        try require(cardChoice.state == (model.displayStyle == .card ? .on : .off)
                    && duoChoice.state == (model.displayStyle == .duo ? .on : .off),
                    "style settings lost their selected state")
        try pressSetting("back", in: panel)
        try pressSetting("nav.language", in: panel)
        let languageBefore = model.language
        for language in [YuliangLanguage.en, .ja, .zhHans] {
            try pressSetting("language." + language.rawValue, in: panel)
            try require(model.language == language && YuliangL10n.language == language,
                        "language option failed to update the shared current locale")
            try require(StandaloneSettingsPresenter.shellTestPanel === panel && isOnScreen(panel),
                        "switching language replaced or closed the stable settings panel")
            _ = try settingsButton("language." + language.rawValue, in: panel)
            let expectedTitle = YuliangL10n.text("语言")
            let title = descendant(panel.contentView!, identifier: "yuliang.settings.pageTitle") as? NSTextField
            try require(title?.stringValue == expectedTitle, "settings title did not update to the selected language")
            if capturePages, let content = panel.contentView {
                try render(content, named: "native-language-\(language.rawValue).png")
            }
        }
        model.language = languageBefore
        settle(0.2)
        try pressSetting("back", in: panel)
        try pressSetting("nav.display", in: panel)
        let dailyChoice = try settingsButton("display.dailyTokens", in: panel)
        let lifetimeChoice = try settingsButton("display.lifetimeTokens", in: panel)
        try require(dailyChoice.state == (dailyBefore ? .on : .off)
                    && lifetimeChoice.state == (lifetimeBefore ? .on : .off),
                    "Token settings lost their independent selected states")
        for _ in 0..<6 {
            model.now = Date()
            model.collector.shellTestSetTokenUsage(tokens)
            settle(0.22)
            try require(StandaloneSettingsPresenter.shellTestPanel === panel && isOnScreen(panel),
                        "settings panel disappeared during model or collector publications")
            try require(desktop.frame.size == widgetSize,
                        "a model/collector publication resized the fixed widget beneath settings")
            _ = try settingsButton("display.dailyTokens", in: panel)
        }
        // Both changes happen inside one continuously visible surface.
        try pressSetting("display.dailyTokens", in: panel)
        try pressSetting("display.lifetimeTokens", in: panel)
        try require(model.showDailyTokens != dailyBefore && model.showLifetimeTokens != lifetimeBefore,
                    "continuous settings selections did not independently change both Token preferences")
        try require(desktop.frame.size == widgetSize,
                    "continuous Token preference changes resized the fixed widget")
        try pressSetting("display.dailyTokens", in: panel)
        try pressSetting("display.lifetimeTokens", in: panel)
        try pressSetting("back", in: panel)
        try pressSetting("nav.interactions", in: panel)
        for action in BuddyAction.interactiveActions {
            _ = try settingsButton("interaction." + action.rawValue, in: panel)
        }
        try pressSetting("interaction." + BuddyAction.dance.rawValue, in: panel)
        try require(model.buddyActivity?.action == .dance && model.buddyActivity?.source == .play,
                    "settings interaction did not dispatch the selected action")
        try require(desktop.frame.size == widgetSize,
                    "an interaction response resized the fixed widget")
        if let content = desktop.contentView {
            try render(content, named: "native-\(prefix)-interaction-feedback.png")
        }
        model.buddyActivity = nil
        try pressSetting("back", in: panel)
        if capturePages {
            for (name, appearanceId) in [("light", "light"), ("dark", "dark")] {
                try pressSetting("nav.appearance", in: panel)
                try pressSetting("appearance." + appearanceId, in: panel)
                try require(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (name == "dark" ? .darkAqua : .aqua),
                            "settings panel did not apply the selected native appearance")
                if let content = panel.contentView {
                    try render(content, named: "native-settings-appearance-\(name).png")
                }
                try pressSetting("back", in: panel)
                if let content = panel.contentView {
                    try render(content, named: "native-settings-home-\(name).png")
                }
                try pressSetting("nav.display", in: panel)
                if let content = panel.contentView {
                    try render(content, named: "native-settings-display-\(name).png")
                }
                try pressSetting("back", in: panel)
            }
        }
        try pressSetting("close", in: panel, staysOpen: false)
        try require(!isOnScreen(panel) && StandaloneSettingsPresenter.shellTestPanel == nil && !StandaloneMenuTracking.isActive,
                    "settings close did not end the independent panel's presentation")
        try require(model.document.records == records && model.collector.tokenUsage == tokens
                    && model.collector.tokenUsageLastSuccessAt == tokens.observedAt
                    && !model.collector.isRunning && model.collector.lastAttemptAt == nil,
                    "settings interactions changed account data or started a collector query")
        if capturePages, let content = desktop.contentView,
           let trigger = descendant(content, identifier: "yuliang.interactions.button") as? NSButton {
            trigger.performClick(nil)
            settle(0.2)
            let actions = try settingsPanel()
            for action in BuddyAction.interactiveActions {
                _ = try settingsButton("interaction." + action.rawValue, in: actions)
            }
            try pressSetting("interaction." + BuddyAction.dance.rawValue, in: actions)
            try require(model.buddyActivity?.action == .dance, "interaction trigger did not dispatch its real action button")
            try pressSetting("close", in: actions, staysOpen: false)
            model.buddyActivity = nil
        }
        guard let content = desktop.contentView,
              let context = descendant(content, identifier: "yuliang.buddy.contextMenu"),
              let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: desktop.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw ShellCheckFailure(description: "character has no native contextual interaction receiver")
        }
        // Send only to this process's own view; no operating-system event posting.
        context.rightMouseDown(with: rightClick)
        settle(0.2)
        let contextualActions = try settingsPanel()
        let signature = try settingsButton("interaction.signature", in: contextualActions)
        try require(signature.title == YuliangL10n.text(model.document.preferences.character.signatureLabel),
                    "character right-click lost its own signature entry")
        try pressSetting("interaction.signature", in: contextualActions)
        try require(model.buddyActivity?.action == model.document.preferences.character.signatureAction,
                    "character right-click did not dispatch its signature action")
        model.buddyActivity = nil
        for action in BuddyAction.interactiveActions {
            _ = try settingsButton("interaction." + action.rawValue, in: contextualActions)
        }
        contextualActions.cancelOperation(nil)
        settle(0.15)
        try require(StandaloneSettingsPresenter.shellTestPanel == nil && !StandaloneMenuTracking.isActive,
                    "contextual interaction panel did not close through native Escape cancellation")
        if capturePages,
           let receiver = descendant(content, identifier: "yuliang.widget.contextMenu") as? StandaloneWidgetContextMenu.ContextView {
            let point = receiver.convert(NSPoint(x: 8, y: 8), to: nil)
            guard let controlClick = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.control],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: desktop.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: 1) else {
                throw ShellCheckFailure(description: "could not construct a local Control-click event")
            }
            try require(receiver.acceptsContextClick(controlClick, at: point),
                        "background settings rejected macOS Control-click")
            receiver.mouseDown(with: controlClick)
            settle(0.2)
            let controlPanel = try settingsPanel()
            _ = try settingsButton("nav.sources", in: controlPanel)
            try pressSetting("close", in: controlPanel, staysOpen: false)
            try require(receiver.accessibilityPerformShowMenu(), "public AXShowMenu did not dispatch contextual settings")
            settle(0.2)
            let accessiblePanel = try settingsPanel()
            _ = try settingsButton("nav.appearance", in: accessiblePanel)
            try pressSetting("close", in: accessiblePanel, staysOpen: false)
        }
        print("Persistent settings panel verified: \(prefix), complete titles, continuous selections and six model publications")
    }

    @MainActor
    private static func checkClaudeSources(model: StandaloneModel, shell: StandaloneAppDelegate,
                                          tokens: TokenUsageSnapshot) throws {
        let desktop = shell.shellTestPanel
        let records = model.document.records
        let preferences = model.document.preferences
        let style = model.displayStyle
        let appearance = model.appearance
        let companion = model.companionEnabled
        let daily = model.showDailyTokens
        let lifetime = model.showLifetimeTokens
        let companionCallback = model.onCompanionChange
        let connectCallback = model.onConnectClaude
        var companionCallbacks: [Bool] = []
        var connectCallbacks = 0
        model.onCompanionChange = { value in
            companionCallbacks.append(value)
            companionCallback?(value)
        }
        // Verify the real source-page button's dispatch without opening a real
        // account page or starting network access from this synthetic harness.
        model.onConnectClaude = { connectCallbacks += 1 }
        defer {
            StandaloneSettingsPresenter.close()
            model.onConnectClaude = connectCallback
            model.onCompanionChange = companionCallback
            model.companionEnabled = companion
            model.showDailyTokens = daily
            model.showLifetimeTokens = lifetime
            model.displayStyle = style
            model.appearance = appearance
            model.preference { $0 = preferences }
            model.buddyActivity = nil
            settle(0.3)
        }
        guard let content = desktop.contentView else {
            throw ShellCheckFailure(description: "source test has no actual desktop view")
        }
        // Establish this test's own baseline independently of earlier display
        // switches, and restore the caller's settings in the defer above.
        model.selectProvider(.codex)
        model.showDailyTokens = true
        model.showLifetimeTokens = true
        settle(0.3)
        // Earlier positive pixel-difference checks prove both Codex Token rows
        // are rendered. Here the same switches must leave Claude's pixels
        // unchanged. SwiftUI virtual AX text is inspected through CUA during
        // interactive acceptance; this own-process harness cannot expose it
        // reliably when macOS has not enabled enhanced accessibility.
        try require(model.showDailyTokens && model.showLifetimeTokens && model.collector.tokenUsage == tokens,
                    "source check did not retain both independent Codex Token readings")
        let panel = try openSettings(on: desktop)
        try pressSetting("nav.sources", in: panel)
        _ = try settingsButton("source.connectClaude", in: panel)
        _ = try settingsButton("source.details", in: panel)
        for provider in [QuotaProvider.claude, .codex, .claude] {
            try pressSetting("source." + provider.rawValue, in: panel)
            let stored = try model.store.read()
            try require(model.document.preferences.providerId == provider && stored.preferences.providerId == provider,
                        "source selection did not persist its actual provider: \(provider.rawValue)")
            for choice in [QuotaProvider.codex, .claude] {
                let button = try settingsButton("source." + choice.rawValue, in: panel)
                try require(button.state == (choice == provider ? .on : .off),
                            "source selection lost the visible radio state: \(choice.rawValue)")
            }
            let label = shell.shellTestStatusButton?.accessibilityLabel() ?? ""
            let tooltip = shell.shellTestStatusButton?.toolTip ?? ""
            try require(label.contains(provider.name) && tooltip.contains(provider.name),
                        "real status-item label and tooltip retained the previous provider")
            if provider == .claude {
                let presentation = QuotaPresentation(document: model.document, now: model.now)
                try require(presentation.provider == .claude && presentation.remainingPercent == 72
                            && model.windows.contains(where: { $0.id == "weekly" && $0.remainingPercent == 39 }),
                            "Claude card did not receive its own synthetic windows")
                // Source transitions take 0.24s, while pressSetting intentionally
                // exercises rapid consecutive choices with only a 0.15s wait.
                // Compare settled information, not two different animation frames.
                settle(0.35)
                let enabled = try render(content, named: "native-claude-card-token-settings-on.png")
                model.showDailyTokens = false
                model.showLifetimeTokens = false
                settle(0.35)
                let disabled = try render(content, named: "native-claude-card-token-settings-off.png")
                try require(pixelDifference(enabled, disabled) < 0.001,
                            "Codex Token switches altered the actual Claude rendering")
                model.showDailyTokens = true
                model.showLifetimeTokens = true
                settle(0.2)
                try require(model.showDailyTokens && model.showLifetimeTokens && model.collector.tokenUsage == tokens,
                            "switching sources erased the independently enabled Codex Token settings or readings")
            }
            try require(desktop.frame.size == expectedCardSize && StandaloneSettingsPresenter.shellTestPanel === panel,
                        "continuous source choices resized the widget or replaced the settings session")
        }
        // Publications from the other reader cannot dismiss the source page or
        // leak its counters into Claude's selected view.
        let beforeOtherPublication = try render(content, named: "native-claude-before-codex-publication.png")
        for _ in 0..<3 {
            model.collector.shellTestSetTokenUsage(tokens)
            model.now = Date()
            settle(0.2)
            try require(StandaloneSettingsPresenter.shellTestPanel === panel && isOnScreen(panel),
                        "a Codex publication dismissed source settings")
        }
        let afterOtherPublication = try render(content, named: "native-claude-after-codex-publication.png")
        try require(pixelDifference(beforeOtherPublication, afterOtherPublication) < 0.001,
                    "a Codex publication changed Claude's actual rendered information")
        try pressSetting("source.connectClaude", in: panel)
        try require(connectCallbacks == 1 && model.document.preferences.providerId == .claude,
                    "real Claude connect setting did not dispatch the selected provider callback once")
        if let body = panel.contentView { try render(body, named: "native-settings-sources-claude.png") }
        model.appearance = .light
        settle(0.2)
        try render(content, named: "native-claude-card-light.png")
        model.buddyActivity = nil
        model.displayStyle = .duo
        model.appearance = .dark
        settle(0.5)
        try require(desktop.frame.size == expectedDuoSize, "Claude Duo changed its fixed size")
        let duoEnabled = try render(content, named: "native-claude-duo-dark.png")
        model.showDailyTokens = false
        model.showLifetimeTokens = false
        settle(0.35)
        let duoDisabled = try render(content, named: "native-claude-duo-token-settings-off.png")
        try require(pixelDifference(duoEnabled, duoDisabled) < 0.001,
                    "Codex Token switches altered the actual Claude Duo rendering")
        model.showDailyTokens = true
        model.showLifetimeTokens = true
        model.displayStyle = .card
        settle(0.3)
        try pressSetting("back", in: panel)
        try pressSetting("nav.display", in: panel)
        let choice = try settingsButton("display.companion", in: panel)
        try require(choice.state == (companion ? .on : .off), "autonomous companion setting lost its selected state")
        try pressSetting("display.companion", in: panel)
        try pressSetting("display.companion", in: panel)
        try require(model.companionEnabled == companion && companionCallbacks == [!companion, companion],
                    "continuous autonomous-companion choices did not dispatch both persistence callbacks")
        try require(model.document.records == records && model.collector.tokenUsage == tokens
                    && !model.collector.isRunning && !model.collector.isBusy && model.collector.lastAttemptAt == nil
                    && !model.claudeCollector.isRunning && !model.claudeCollector.isBusy
                    && model.claudeCollector.lastAttemptAt == nil && model.claudeCollector.webView.url == nil,
                    "source or companion controls mutated readings or started account/network access")
        print("Synthetic source settings verified: persistent Claude/Codex selection, rendered Token isolation, companion persistence callbacks; rail click/virtual AX accepted separately through CUA")
    }

    @MainActor
    private static func checkWidgetColors(model: StandaloneModel, shell: StandaloneAppDelegate,
                                          tokens: TokenUsageSnapshot) throws {
        let desktop = shell.shellTestPanel
        let originalColor = model.widgetColorStyle
        let originalForeground = model.desktopIsForeground
        let originalAppearance = model.appearance
        let originalCompanion = model.companionEnabled
        let callback = model.onWidgetColorChange
        let records = model.document.records
        let preferences = model.document.preferences
        let presentation = QuotaPresentation(document: model.document, now: model.now)
        let geometry = desktop.frame
        let menuSize = shell.shellTestPopover.contentSize
        var changes: [StandaloneWidgetColorStyle] = []
        model.onWidgetColorChange = { style in changes.append(style); callback?(style) }
        model.companionEnabled = false
        model.buddyActivity = nil
        defer {
            StandaloneSettingsPresenter.close()
            model.onWidgetColorChange = callback
            model.widgetColorStyle = originalColor
            model.desktopIsForeground = originalForeground
            model.appearance = originalAppearance
            model.companionEnabled = originalCompanion
            settle(0.3)
        }
        guard let content = desktop.contentView,
              let material = descendant(content, identifier: "yuliang.widget.material") as? NSVisualEffectView else {
            throw ShellCheckFailure(description: "desktop is missing its real native widget material")
        }
        let panel = try openSettings(on: desktop)
        try pressSetting("nav.appearance", in: panel)
        try pressSetting("appearance.light", in: panel)
        guard let lightVeil = descendant(content, identifier: "yuliang.widget.lightVeil") else {
            throw ShellCheckFailure(description: "light desktop is missing its snow-white material overlay")
        }
        try require(!lightVeil.isHidden, "light appearance did not show its white surface")
        for choice in StandaloneWidgetColorStyle.allCases {
            _ = try settingsButton("widgetColor." + choice.rawValue, in: panel)
        }
        func requireIndependentGroups(color: StandaloneWidgetColorStyle, theme: StandaloneAppearance) throws {
            for candidate in StandaloneAppearance.allCases {
                let button = try settingsButton("appearance." + candidate.rawValue, in: panel)
                try require(button.state == (candidate == theme ? .on : .off),
                            "changing widget color cancelled or changed the separate light/dark radio selection")
            }
            for candidate in StandaloneWidgetColorStyle.allCases {
                let button = try settingsButton("widgetColor." + candidate.rawValue, in: panel)
                try require(button.state == (candidate == color ? .on : .off),
                            "changing light/dark appearance cancelled or changed the separate widget-color radio selection")
            }
        }
        try requireIndependentGroups(color: model.widgetColorStyle, theme: .light)
        func capture(_ name: String, foreground: Bool) throws {
            model.desktopIsForeground = foreground
            settle(0.45)
            let current = QuotaPresentation(document: model.document, now: model.now)
            try require(desktop.frame == geometry && shell.shellTestPopover.contentSize == menuSize,
                        "a foreground/color transition changed the real widget's geometry")
            try require(model.document.records == records && model.document.preferences == preferences
                        && current.remainingPercent == presentation.remainingPercent && current.observedAt == presentation.observedAt
                        && model.collector.tokenUsage == tokens && model.collector.tokenUsageLastSuccessAt == tokens.observedAt,
                        "a foreground/color transition changed quota, Token readings or their successful observation times")
            try require(StandaloneSettingsPresenter.shellTestPanel === panel && isOnScreen(panel),
                        "a foreground/color transition dismissed the continuously open appearance panel")
            try require(!lightVeil.isHidden,
                        "a foreground or monochrome change made light appearance lose its white surface")
            // This native cache documents material/geometry only. cacheDisplay
            // bypasses SwiftUI compositor color filters; ImageRenderer also
            // cannot render this NSViewRepresentable tree. Full-color versus
            // monochrome composition is accepted separately on the real screen.
            try render(content, named: "native-widget-material-" + name + ".png")
        }
        try pressSetting("widgetColor.automatic", in: panel)
        try requireIndependentGroups(color: .automatic, theme: .light)
        try capture("automatic-foreground", foreground: true)
        try require(material.material == .underWindowBackground && material.blendingMode == .behindWindow
                    && material.state == .active,
                    "foreground automatic style did not use the active native widget material")
        try capture("automatic-background", foreground: false)
        try require(material.state == .inactive, "background automatic style retained the emphasized native material")
        try pressSetting("widgetColor.fullColor", in: panel)
        try requireIndependentGroups(color: .fullColor, theme: .light)
        try capture("fullColor-background", foreground: false)
        try require(material.state == .active, "forced full color did not preserve its active material in the background")
        try capture("fullColor-foreground", foreground: true)
        try require(material.state == .active, "forced full color did not preserve its active native material")
        try pressSetting("widgetColor.monochrome", in: panel)
        try requireIndependentGroups(color: .monochrome, theme: .light)
        try capture("monochrome-foreground", foreground: true)
        try require(material.state == .inactive, "forced monochrome did not preserve its inactive material in the foreground")
        try capture("monochrome-background", foreground: false)
        try require(material.state == .inactive, "forced monochrome did not preserve its inactive native material")
        try pressSetting("widgetColor.automatic", in: panel)
        try require(changes == [.automatic, .fullColor, .monochrome, .automatic],
                    "appearance radio choices did not dispatch every color persistence callback")
        try requireIndependentGroups(color: .automatic, theme: .light)
        try pressSetting("appearance.dark", in: panel)
        try requireIndependentGroups(color: .automatic, theme: .dark)
        try require(lightVeil.isHidden, "dark appearance retained the light-only white overlay")
        try render(content, named: "native-widget-material-dark.png")
        try pressSetting("appearance.light", in: panel)
        try require(!lightVeil.isHidden, "returning to light appearance did not restore its white surface")
        try requireIndependentGroups(color: .automatic, theme: .light)
        try require(!model.collector.isRunning && model.collector.lastAttemptAt == nil
                    && !model.claudeCollector.isRunning && model.claudeCollector.lastAttemptAt == nil,
                    "color/background controls triggered an account query")
        if let body = panel.contentView { try render(body, named: "native-settings-widget-colors.png") }
        print("Native widget appearance controls verified: independent radio groups, automatic/forced material states, persistence callbacks and unchanged data/geometry; compositor color requires separate real-screen acceptance")
    }

    @MainActor
    private static func renderGaugeBoundaries(now: Date, preferences: QuotaPreferences) throws {
        let states: [(String, Double?)] = [
            ("empty", 0), ("low", 22), ("quarter", 25), ("half", 50),
            ("two-thirds", 68), ("three-quarters", 75), ("full", 100), ("unknown", nil)
        ]
        for dark in [false, true] {
            for (name, remaining) in states {
                var selected = preferences
                selected.windowId = "primary"
                let snapshot = SnapshotEnvelope(providerId: .codex, pageKind: "rate-limits", observedAt: now,
                    source: "codex-app-server", windows: [QuotaWindow(id: "primary", label: "5小时额度",
                        usedPercent: remaining.map { 100 - $0 }, resetAt: now.addingTimeInterval(7_200), observedAt: now)],
                    id: "synthetic-rail-boundary-\(name)")
                let document = QuotaStoreDocument(records: [snapshot], preferences: selected)
                let host = NSHostingView(rootView: VStack(spacing: 12) {
                    QuotaCard(document: document, now: now, compact: true, minimal: true, slim: true)
                    QuotaDuoGauge(document: document, now: now)
                }.padding(12).frame(width: expectedCardSize.width).background(QuotaPalette.surface)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: expectedCardSize.width, height: 180),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(host.fittingSize)
                window.center()
                window.orderFrontRegardless()
                settle(0.1)
                try require(isOnScreen(window), "synthetic gauge boundary fixture was not rendered on screen")
                try render(host, named: "native-gauges-\(name)-\(dark ? "dark" : "light").png")
                window.close()
            }
        }
    }

    @MainActor
    private static func renderNewInteractionStages(now: Date, preferences: QuotaPreferences) throws {
        let signatures = QuotaCharacter.builtInCharacters.map { character in
            (character.signatureAction, character, character.signatureAction.duration * 0.45)
        }
        let examples = signatures + [(.eating, QuotaCharacter.nailong, 1.35), (.eating, .swordCat, 1.35)]
        for dark in [false, true] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                Text("合成互动预览 · 固定阶段")
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(examples.indices, id: \.self) { index in
                        let (action, character, elapsed) = examples[index]
                        let activity = BuddyActivity(action: action, startedAt: now, source: .play)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(character.name) · \(action == character.signatureAction ? character.signatureLabel : action.label)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            QuotaRail(remainingPercent: 68, character: character, frame: 3,
                                      accent: QuotaPalette.accent(for: character), size: 36,
                                      activity: activity, activityPreviewElapsed: elapsed,
                                      onAction: { _ in }, trackHeight: 14)
                                .frame(height: 50)
                            Text(action == character.signatureAction ? character.signatureCaption() : activity.caption)
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(height: 100, alignment: .topLeading)
                    }
                }
            }.padding(16).frame(width: 640).background(QuotaPalette.surface)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.center()
            window.orderFrontRegardless()
            settle(0.1)
            try require(isOnScreen(window), "fixed-elapsed synthetic interaction stages were not rendered on screen")
            try render(host, named: "native-new-interactions-\(dark ? "dark" : "light").png")
            window.close()
        }
    }

    @MainActor
    private static func renderLocalizedLayouts(model: StandaloneModel, shell: StandaloneAppDelegate) throws {
        let language = model.language
        let compact = model.compact
        let appearance = model.appearance
        let colors = model.widgetColorStyle
        let style = model.displayStyle
        let activity = model.buddyActivity
        let feedback = model.buddyFeedback
        let records = model.document.records
        defer {
            model.language = language
            model.compact = compact
            model.appearance = appearance
            model.widgetColorStyle = colors
            model.displayStyle = style
            model.buddyActivity = activity
            model.buddyFeedback = feedback
            settle(0.25)
            shell.shellTestResize()
        }
        model.widgetColorStyle = .fullColor
        for selectedLanguage in [YuliangLanguage.zhHans, .en, .ja] {
            model.language = selectedLanguage
            for dark in [false, true] {
                model.appearance = dark ? .dark : .light
                model.displayStyle = .card
                for isCompact in [false, true] {
                    model.compact = isCompact
                    settle(0.55)
                    shell.shellTestResize()
                    let panel = shell.shellTestPanel
                    try require(panel.frame.size == (isCompact ? expectedCompactSize : expectedCardSize),
                                "localized layout changed its documented footprint")
                    if let content = panel.contentView {
                        try render(content, named: "native-\(isCompact ? "compact" : "standard")-\(selectedLanguage.rawValue)-\(dark ? "dark" : "light").png")
                    }
                }
                // Exercise a real long interaction caption in the small Duo
                // footprint, not only the shorter single-line Chinese footer.
                // Three deterministic choices select the first theme phrase.
                model.displayStyle = .duo
                model.buddyFeedback = BuddyFeedbackState()
                for _ in 0..<3 { model.play(model.document.preferences.character.signatureAction) }
                settle(0.55)
                shell.shellTestResize()
                let panel = shell.shellTestPanel
                try require(panel.frame.size == expectedDuoSize,
                            "localized Duo caption changed the fixed small-widget footprint")
                if let content = panel.contentView {
                    try render(content, named: "native-duo-\(selectedLanguage.rawValue)-\(dark ? "dark" : "light").png")
                }
            }
        }
        try require(model.document.records == records && !model.collector.isRunning && !model.claudeCollector.isRunning,
                    "language or layout previews altered account records or started a collector")
    }

    @MainActor
    private static func runChecks() throws {
        try checkDuoGeometry()
        for compact in [true, false] {
            let expected = compact ? expectedCompactSize : expectedCardSize
            try require(StandaloneLayout.cardWidth(compact: compact) == expected.width
                        && StandaloneLayout.cardHeight(compact: compact) == expected.height
                        && StandaloneLayout.desktopWidth(style: .card, compact: compact) == expected.width
                        && StandaloneLayout.desktopHeight(style: .card, compact: compact) == expected.height
                        && StandaloneLayout.desktopWidth(style: .duo, compact: compact) == expectedDuoSize.width,
                        "standard/compact/Duo footprints do not follow their distinct designed sizes")
        }
        try require(StandaloneLayout.minimumHeight(style: .card) == expectedCardSize.height
                    && StandaloneLayout.minimumHeight(style: .duo) == expectedDuoSize.height,
                    "card/Duo layout no longer uses the fixed widget height")
        try require(StandaloneLayout.cornerRadius == 22,
                    "card/Duo layout no longer shares the 22-point widget corner radius")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuliang-desktop-shell-check-\(UUID().uuidString)", isDirectory: true)
        let model = StandaloneModel(store: StandaloneQuotaStore(directory: directory))
        model.language = .zhHans
        try require(model.showDailyTokens && model.showLifetimeTokens, "both Token counters should be enabled by default")
        try require(model.displayStyle == .card, "existing installations should start in the familiar card style")
        try require(model.availableCharacters.count == 7 && Set(model.availableCharacters).count == 7,
                    "the public build should expose seven distinct selectable characters")
        let syntheticTime = Date()
        let syntheticQuota = SnapshotEnvelope(providerId: .codex, pageKind: "rate-limits", observedAt: syntheticTime,
            source: "codex-app-server", windows: [
                QuotaWindow(id: "primary", label: "5小时额度", usedPercent: 32,
                    resetAt: syntheticTime.addingTimeInterval(7_200), note: "Synthetic UI fixture only", observedAt: syntheticTime),
                QuotaWindow(id: "secondary", label: "7天额度", usedPercent: 54,
                    resetAt: syntheticTime.addingTimeInterval(86_400), note: "Synthetic UI fixture only", observedAt: syntheticTime),
            ], id: "synthetic-shell-fixture")
        try model.collector.onSnapshot?(syntheticQuota)
        let syntheticClaude = SnapshotEnvelope(providerId: .claude, pageKind: "usage", observedAt: syntheticTime,
            source: "browser", windows: [
                QuotaWindow(id: "session", label: "当前会话", usedPercent: 28,
                    resetAt: syntheticTime.addingTimeInterval(10_800), note: "Synthetic Claude UI fixture only", observedAt: syntheticTime),
                QuotaWindow(id: "weekly", label: "每周全部模型", usedPercent: 61,
                    resetAt: syntheticTime.addingTimeInterval(172_800), note: "Synthetic Claude UI fixture only", observedAt: syntheticTime),
                QuotaWindow(id: "sonnet-weekly", label: "每周 Sonnet", usedPercent: nil,
                    resetAt: nil, note: "Synthetic unknown value only", observedAt: syntheticTime),
            ], id: "synthetic-claude-shell-fixture")
        try model.claudeCollector.onSnapshot?(syntheticClaude)
        let syntheticTokens = TokenUsageSnapshot(todayTokens: nil, serverDayTokens: 12_345,
            serverDay: "2026-11-03", lifetimeTokens: 1_234_567, peakDailyTokens: 45_678,
            currentStreakDays: 8, longestStreakDays: 14, longestRunningTurnSec: 540,
            observedAt: syntheticTime, sourceLabel: "Synthetic UI fixture · 服务端日统计")
        model.collector.shellTestSetTokenUsage(syntheticTokens)
        let originalRecords = model.document.records
        let originalAppearance = NSApp.appearance
        let shell = StandaloneAppDelegate()
        shell.prepareForShellTesting(model: model)
        // This direct-call harness owns a bounded event pump rather than the
        // application's normal run loop. Test native open/close lifecycle
        // without relying on AppKit animation transaction completion.
        shell.shellTestPopover.animates = false
        shell.shellTestCharacterPopover.animates = false
        defer {
            shell.shellTestConnectionWindow?.close()
            shell.shellTestTearDown()
            NSApp.appearance = originalAppearance
            try? FileManager.default.removeItem(at: directory)
        }
        settle()
        let panel = shell.shellTestPanel
        let collectorIdentity = ObjectIdentifier(model.collector)
        try require(app.activationPolicy() == .accessory, "test app should have no Dock icon")
        try require(!panel.styleMask.contains(.titled), "desktop card still has a title bar")
        try require(panel.styleMask.contains(.nonactivatingPanel), "desktop card should not activate other app windows")
        try require(panel.standardWindowButton(.closeButton) == nil, "desktop card still has traffic-light buttons")
        try require(!panel.isOpaque && panel.backgroundColor == .clear, "desktop corners need a transparent window")
        try require(!panel.isVisible && !model.desktopVisible, "test setup must not show desktop unexpectedly")
        try require(shell.shellTestSurfacesShareModel, "desktop and menu surfaces must share one model")
        try require(!model.positionLocked && panel.isMovable && panel.isMovableByWindowBackground,
                    "new card should be freely draggable across its window background")
        try require(!model.collector.isRunning && !model.collector.isBusy, "UI test unexpectedly started the collector")
        try require(model.collector.interval == 60, "UI shell changed the 60-second collection interval")

        shell.shellTestShowDesktop()
        settle()
        try checkPersistentSettings(model: model, desktop: panel, tokens: syntheticTokens, prefix: "card", capturePages: true)
        settle(0.3) // Restore Token preferences before checking fixed widget geometry.
        try checkWidgetColors(model: model, shell: shell, tokens: syntheticTokens)
        try require(model.desktopVisible && panel.isVisible, "desktop card cannot be shown")
        try require(panel.level == .floating, "default desktop card should be floating")
        let compactHeight = panel.frame.height
        try require(panel.frame.size == expectedCardSize,
                    "card did not adopt its fixed 344-by-160-point widget size")
        // Visibility preferences alter rendered rows without resizing either
        // widget surface or changing the underlying collection state.
        // The same paused collector and both underlying readings stay intact.
        let allTokensHeight = panel.frame.height
        let allTokensMenuHeight = shell.shellTestPopover.contentSize.height
        guard let tokenCardView = panel.contentView else { throw ShellCheckFailure(description: "card content missing") }
        let bothTokens = try render(tokenCardView, named: "native-main-both-tokens.png")
        try setting(["显示内容", "日 Token 用量"], shell: shell)
        settle(0.3)
        try require(!model.showDailyTokens && model.showLifetimeTokens,
                    "native daily Token action changed the wrong display preference")
        let lifetimeOnly = try render(tokenCardView, named: "native-main-lifetime-only.png")
        try require(pixelDifference(bothTokens, lifetimeOnly) > 0.002,
                    "daily switch did not change the actual rendered Token row")
        try require(abs(panel.frame.height - allTokensHeight) <= 1, "one Token value should use the existing compact row")
        model.showDailyTokens = true
        model.showLifetimeTokens = false
        settle(0.3)
        let dailyOnly = try render(tokenCardView, named: "native-main-daily-only.png")
        try require(pixelDifference(bothTokens, dailyOnly) > 0.002 && pixelDifference(dailyOnly, lifetimeOnly) > 0.001,
                    "independent daily/lifetime switches did not produce distinct native row content")
        model.showDailyTokens = false
        settle(0.3)
        try render(tokenCardView, named: "native-main-no-tokens.png")
        try require(panel.frame.size == expectedCardSize
                    && abs(shell.shellTestPopover.contentSize.height - allTokensMenuHeight) <= 1,
                    "hiding both Token counters changed a widget surface's fixed size")
        model.showDailyTokens = true
        model.showLifetimeTokens = true
        settle(0.3)
        try require(abs(panel.frame.height - allTokensHeight) <= 1
                    && abs(shell.shellTestPopover.contentSize.height - allTokensMenuHeight) <= 1,
                    "restoring both Token values changed a widget surface's fixed size")
        try checkClaudeSources(model: model, shell: shell, tokens: syntheticTokens)

        // Changing style resizes the actual native desktop window while the
        // menu popover keeps its full card. Neither surface owns a new reader.
        let beforeDuo = panel.frame
        try setting(["小组件样式", "Duo 圆环"], shell: shell)
        settle(0.4)
        try require(model.displayStyle == .duo, "native Duo style action did not update the shared model")
        try require(panel.frame.size == expectedDuoSize,
                    "Duo did not adopt its fixed 160-by-160-point small-widget size")
        try checkPersistentSettings(model: model, desktop: panel, tokens: syntheticTokens, prefix: "duo", capturePages: false)
        settle(0.3)
        try require(panel.frame.width * panel.frame.height < beforeDuo.width * beforeDuo.height * 0.55,
                    "Duo desktop footprint is not materially smaller than the compact card")
        try require(abs(panel.frame.maxY - beforeDuo.maxY) <= 1 && abs(panel.frame.minX - beforeDuo.minX) <= 1,
                    "switching from card to Duo moved the remembered top-left position")
        try require(abs(shell.shellTestPopover.contentSize.width - expectedCardSize.width) <= 1,
                    "Duo mode incorrectly shrank the detailed menu popover to icon width")
        guard let statusButton = shell.shellTestStatusButton else {
            throw ShellCheckFailure(description: "Duo status button is missing")
        }
        try require(statusButton.title.isEmpty && statusButton.image?.isTemplate == true,
                    "Duo menu-bar status should be a template icon without a text label")
        try require((statusButton.image?.size.width ?? 0) <= 24 && (statusButton.image?.size.height ?? 0) <= 24,
                    "Duo status icon no longer fits the normal menu-bar icon size")
        try require(!(statusButton.toolTip ?? "").isEmpty, "icon-only menu status lost its accessible quota description")
        let duoBothHeight = panel.frame.height
        let duoBoth = try render(tokenCardView, named: "native-duo-both-tokens.png")
        try render(statusButton, named: "native-duo-menubar-icon.png")
        model.showDailyTokens = false
        settle(0.3)
        let duoLifetimeOnly = try render(tokenCardView, named: "native-duo-lifetime-only.png")
        let duoSingleHeight = panel.frame.height
        try require(panel.frame.size == expectedDuoSize && abs(duoSingleHeight - duoBothHeight) <= 1
                    && pixelDifference(duoBoth, duoLifetimeOnly) > 0.002,
                    "Duo daily switch did not independently hide its Token content while preserving fixed geometry")
        model.showDailyTokens = true
        model.showLifetimeTokens = false
        settle(0.3)
        let duoDailyOnly = try render(tokenCardView, named: "native-duo-daily-only.png")
        try require(abs(panel.frame.height - duoSingleHeight) <= 1 && pixelDifference(duoDailyOnly, duoLifetimeOnly) > 0.001,
                    "Duo single-counter choices are not independently rendered at the same fixed size")
        model.showDailyTokens = false
        settle(0.3)
        try render(tokenCardView, named: "native-duo-no-tokens.png")
        try require(panel.frame.size == expectedDuoSize,
                    "hiding both Duo Token counters changed the fixed small-widget size")
        model.showDailyTokens = true
        model.showLifetimeTokens = true
        try setting(["外观", "浅色"], shell: shell)
        settle(0.4)
        let duoLight = try render(tokenCardView, named: "native-duo-light.png")
        try setting(["外观", "深色"], shell: shell)
        settle(0.4)
        let duoDark = try render(tokenCardView, named: "native-duo-dark.png")
        try require(abs(panel.frame.height - duoBothHeight) <= 1 && luminance(duoLight) - luminance(duoDark) > 0.25,
                    "Duo did not restore both counters or change its native pixels for dark mode")
        guard let duoContent = panel.contentView,
              let duoDrag = descendant(duoContent, identifier: "yuliang.desktop.dragHandle") else {
            throw ShellCheckFailure(description: "Duo has no discoverable native drag handle")
        }
        try require(duoDrag.bounds.width >= 40 && duoDrag.bounds.height >= 10 && duoDrag.acceptsFirstMouse(for: nil),
                    "Duo drag handle is too small or discards the initial click")
        model.desktopVisible = false
        settle(0.2)
        shell.shellTestTogglePopover()
        settle(0.3)
        try require(!panel.isVisible && shell.shellTestPopover.isShown
                    && abs(shell.shellTestPopover.contentSize.width - expectedCardSize.width) <= 1,
                    "hiding Duo prevented the menu icon from opening the full compact card")
        if let view = shell.shellTestPopover.contentViewController?.view {
            try render(view, named: "native-duo-menubar-card.png")
        }
        model.onShowDesktop?()
        settle(0.3)
        try require(panel.isVisible && model.desktopVisible && model.displayStyle == .duo
                    && panel.frame.size == expectedDuoSize && !shell.shellTestPopover.isShown,
                    "menu recall lost the Duo style or failed to restore the desktop icon")
        model.onChooseCharacter?(.desktop)
        settle(0.4)
        try require(shell.shellTestCharacterPopover.isShown
                    && isOnScreen(shell.shellTestCharacterPopover.contentViewController?.view.window),
                    "Duo cannot anchor a visible native character picker")
        let beforeRestoringCard = panel.frame
        guard let restoringScreen = panel.screen else {
            throw ShellCheckFailure(description: "Duo window has no screen for restoring the wider card")
        }
        let visible = restoringScreen.visibleFrame
        let expectedRestoredX = max(visible.minX, min(beforeRestoringCard.minX, visible.maxX - expectedCardSize.width))
        let expectedRestoredY = max(visible.minY, min(beforeRestoringCard.maxY - expectedCardSize.height,
                                                    visible.maxY - expectedCardSize.height))
        try setting(["小组件样式", "轻巧卡片"], shell: shell)
        settle(0.4)
        try require(!shell.shellTestCharacterPopover.isShown,
                    "style switching left a character popover anchored to the old geometry")
        try require(panel.frame.size == expectedCardSize && abs(panel.frame.height - allTokensHeight) <= 1,
                    "returning from Duo failed to restore the fixed medium-widget card size")
        try require(abs(panel.frame.minX - expectedRestoredX) <= 1
                    && abs(panel.frame.minY - expectedRestoredY) <= 1 && visible.contains(panel.frame),
                    "returning from right-edge Duo failed to preserve its top anchor and keep the wider card on screen; before=\(beforeRestoringCard), expectedOrigin=(\(expectedRestoredX), \(expectedRestoredY)), actual=\(panel.frame), visible=\(visible)")
        try require(shell.shellTestStatusButton?.image == nil && !(shell.shellTestStatusButton?.title ?? "").isEmpty,
                    "returning to card style failed to restore text menu-bar status")
        try require(ObjectIdentifier(model.collector) == collectorIdentity && model.document.records == originalRecords
                    && model.collector.tokenUsage == syntheticTokens && !model.collector.isRunning
                    && !model.collector.isBusy && model.collector.lastAttemptAt == nil
                    && model.collector.tokenUsageLastAttemptAt == nil,
                    "style and icon controls changed account data or started collection")
        try setting(["互动", BuddyAction.dance.label], shell: shell)
        try require(model.buddyActivity?.action == .dance && model.buddyActivity?.source == .play,
                    "settings interaction panel failed to dispatch the chosen play action")
        try require(model.document.records == originalRecords && model.collector.tokenUsage == syntheticTokens
                    && model.collector.tokenUsageLastSuccessAt == syntheticTime,
                    "settings interaction panel modified account readings or their successful observation time")
        model.buddyActivity = nil
        try renderGaugeBoundaries(now: syntheticTime, preferences: model.document.preferences)
        try renderNewInteractionStages(now: syntheticTime, preferences: model.document.preferences)

        model.appearance = .light
        model.onConnect?()
        settle(0.4)
        guard let details = shell.shellTestConnectionWindow else {
            throw ShellCheckFailure(description: "details callback did not create a native window")
        }
        try require(isOnScreen(details), "details window exists without being on screen")
        func explicitAppearance(_ expected: NSAppearance.Name) throws {
            try require(panel.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expected,
                        "desktop panel did not adopt the selected native appearance")
            try require(shell.shellTestPopover.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expected,
                        "menu popover did not adopt the selected native appearance")
            try require(shell.shellTestCharacterPopover.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expected,
                        "character popover did not adopt the selected native appearance")
            try require(details.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expected,
                        "details window did not adopt the selected native appearance")
        }
        try explicitAppearance(.aqua)
        guard let cardView = panel.contentView else { throw ShellCheckFailure(description: "card content missing") }
        let light = try render(cardView, named: "native-main-light.png")
        model.appearance = .dark
        settle(0.4)
        try explicitAppearance(.darkAqua)
        let dark = try render(cardView, named: "native-main-dark.png")
        try require(luminance(light) - luminance(dark) > 0.25,
                    "native card pixels did not change from a light to a dark surface")
        if let view = details.contentView { try render(view, named: "native-details-dark.png") }
        details.orderOut(nil)
        model.onChooseCharacter?(.desktop)
        settle(0.5)
        try require(shell.shellTestCharacterPopover.isShown
                    && isOnScreen(shell.shellTestCharacterPopover.contentViewController?.view.window),
                    "dark character picker did not create a visible native window")
        if let view = shell.shellTestCharacterPopover.contentViewController?.view {
            try render(view, named: "native-character-picker-dark.png")
        }
        shell.shellTestDismissCharacterPicker()
        settleUntil { !shell.shellTestCharacterPopover.isShown }
        try require(!shell.shellTestCharacterPopover.isShown, "dark character picker did not close after selection")
        shell.shellTestTogglePopover()
        settle(0.4)
        if let view = shell.shellTestPopover.contentViewController?.view { try render(view, named: "native-menubar-dark.png") }
        shell.shellTestTogglePopover()
        settle(0.3)

        model.appearance = .system
        settle(0.3)
        try require(panel.appearance == nil && shell.shellTestPopover.appearance == nil
                    && shell.shellTestCharacterPopover.appearance == nil && details.appearance == nil,
                    "system appearance should clear explicit overrides on every native surface")
        // A nil NSPopover appearance follows macOS itself, including vibrant
        // appearances. Changing NSApp.appearance cannot simulate a global OS
        // theme change, so compare system mode against its actual native value.
        NSApp.appearance = nil
        settle(0.3)
        guard let expectedSystem = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) else {
            throw ShellCheckFailure(description: "macOS did not provide a native system appearance")
        }
        try require(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedSystem
                    && details.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedSystem,
                    "system mode failed to follow macOS in panel/details windows")
        shell.shellTestTogglePopover()
        settle(0.3)
        try require(shell.shellTestPopover.isShown
                    && shell.shellTestPopover.contentViewController?.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedSystem,
                    "system mode failed to follow macOS in visible menu content")
        model.onChooseCharacter?(.menuBar)
        settle(0.4)
        try require(shell.shellTestCharacterPopover.isShown
                    && isOnScreen(shell.shellTestCharacterPopover.contentViewController?.view.window)
                    && shell.shellTestCharacterPopover.contentViewController?.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedSystem,
                    "system mode failed to follow macOS in visible character content")
        shell.shellTestDismissCharacterPicker()
        settleUntil { !shell.shellTestCharacterPopover.isShown }
        try require(!shell.shellTestCharacterPopover.isShown, "system character picker did not close")
        if shell.shellTestPopover.isShown { shell.shellTestTogglePopover(); settle(0.3) }
        try require(model.document.records == originalRecords && model.collector.tokenUsage == syntheticTokens,
                    "display, sizing or theme controls changed underlying quota/Token readings")
        try require(ObjectIdentifier(model.collector) == collectorIdentity && !model.collector.isRunning
                    && !model.collector.isBusy && model.collector.lastAttemptAt == nil
                    && model.collector.tokenUsageLastAttemptAt == nil,
                    "display, sizing or theme controls triggered an account query")
        guard let content = panel.contentView,
              let dragHandle = descendant(content, identifier: "yuliang.desktop.dragHandle") else {
            throw ShellCheckFailure(description: "desktop drag region has no native mouse event receiver")
        }
        try require(dragHandle.bounds.width >= 130 && dragHandle.bounds.height >= 10,
                    "native drag region does not cover the available header space")
        try require(dragHandle.acceptsFirstMouse(for: nil), "drag region discards the first mouse event on a nonactivating panel")
        try require(!dragHandle.mouseDownCanMoveWindow, "header dragging should remain in the AppKit event tracking path")
        let dragPoint = dragHandle.convert(NSPoint(x: dragHandle.bounds.midX, y: dragHandle.bounds.midY), to: content.superview)
        try require(content.hitTest(dragPoint) === dragHandle, "native header hit testing sends a drag to another view")
        let beforeDrag = panel.frame.origin
        let mouseStart = dragHandle.convert(NSPoint(x: dragHandle.bounds.midX, y: dragHandle.bounds.midY), to: nil)
        func mouseEvent(_ type: NSEvent.EventType, location: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw ShellCheckFailure(description: "could not construct a local native drag test event")
            }
            return event
        }
        // Direct calls to this test process's own view validate the tracking
        // algorithm. No CGEvent posting or operating-system mouse injection.
        dragHandle.mouseDown(with: try mouseEvent(.leftMouseDown, location: mouseStart))
        dragHandle.mouseDragged(with: try mouseEvent(.leftMouseDragged, location: NSPoint(x: mouseStart.x - 36, y: mouseStart.y - 22)))
        dragHandle.mouseUp(with: try mouseEvent(.leftMouseUp, location: mouseStart))
        try require(abs(panel.frame.minX - beforeDrag.x + 36) < 0.5 && abs(panel.frame.minY - beforeDrag.y + 22) < 0.5,
                    "native mouseDown/Dragged/Up did not move the card by the requested delta")
        let unlockedFrame = panel.frame
        model.positionLocked = true
        settle()
        try require(!panel.isMovable && !panel.isMovableByWindowBackground, "position lock did not disable AppKit dragging")
        dragHandle.mouseDown(with: try mouseEvent(.leftMouseDown, location: mouseStart))
        dragHandle.mouseDragged(with: try mouseEvent(.leftMouseDragged, location: NSPoint(x: mouseStart.x + 45, y: mouseStart.y + 30)))
        dragHandle.mouseUp(with: try mouseEvent(.leftMouseUp, location: mouseStart))
        try require(panel.frame == unlockedFrame, "locking unexpectedly moved the remembered card position")
        try require(panel.level == .floating, "position lock changed the independent floating preference")
        model.positionLocked = false
        settle()
        try require(panel.isMovable && panel.isMovableByWindowBackground, "unlocking did not restore AppKit dragging")
        try require(panel.frame == unlockedFrame, "unlocking unexpectedly moved the remembered card position")
        let recordsBeforePicker = model.document.records
        model.onChooseCharacter?(.desktop)
        settle(0.6)
        try require(shell.shellTestCharacterPopover.isShown, "desktop character picker did not open")
        try require(isOnScreen(shell.shellTestCharacterPopover.contentViewController?.view.window),
                    "character picker exists in accessibility without a visible native window")
        try require(shell.shellTestCharacterPickerSharesModel, "native character picker has an independent model")
        if let view = shell.shellTestCharacterPopover.contentViewController?.view {
            try render(view, named: "native-character-picker.png")
        }
        try require(model.document.records == recordsBeforePicker, "opening character picker changed quota records")
        shell.shellTestDismissCharacterPicker()
        settleUntil { !shell.shellTestCharacterPopover.isShown }
        try require(!shell.shellTestCharacterPopover.isShown, "character selection dismissal left the native popover open")
        try require(panel.isVisible, "character selection dismissal hid the desktop panel")
        model.compact = false
        settle()
        shell.shellTestResize()
        try require(panel.frame.size == expectedCardSize && abs(panel.frame.height - compactHeight) <= 1,
                    "changing card density resized the fixed medium-widget surface")
        model.compact = true
        // The density transition is 0.36s. Capture its settled compact layout,
        // rather than the larger card halfway through its shrinking frame.
        settle(0.55)
        shell.shellTestResize()
        try require(panel.frame.size == expectedCompactSize && panel.frame.height < compactHeight * 0.75,
                    "compact mode did not materially reduce the actual native footprint")
        if let content = panel.contentView { try render(content, named: "native-main-compact-280x112.png") }
        let compactOrigin = panel.frame
        model.showDailyTokens = false
        model.showLifetimeTokens = false
        settle(0.2)
        try require(panel.frame.size == expectedCompactSize && panel.frame.origin == compactOrigin.origin,
                    "compact Token visibility changes resized or moved the widget")
        model.showDailyTokens = true
        model.showLifetimeTokens = true
        model.compact = false
        settle(0.2)
        shell.shellTestResize()
        try require(panel.frame.size == expectedCardSize && abs(panel.frame.maxY - compactOrigin.maxY) < 1,
                    "restoring standard size did not preserve the widget's top edge")
        try renderLocalizedLayouts(model: model, shell: shell)

        model.pinned = false
        settle()
        try require(panel.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1, "desktop mode uses the wrong window level")
        try require(panel.isMovable && panel.isMovableByWindowBackground, "changing desktop level unexpectedly locked the card")
        model.pinned = true
        settle()
        try require(panel.level == .floating, "pinning failed to restore floating level")
        model.desktopVisible = false
        settle()
        try require(!panel.isVisible, "hide desktop card failed")
        model.onShowDesktop?()
        settle()
        try require(panel.isVisible && model.desktopVisible, "menu callback cannot recall desktop card")

        try require(shell.shellTestStatusButton?.window != nil, "status item has no menu-bar anchor")
        shell.shellTestTogglePopover()
        settle(0.4)
        try require(shell.shellTestPopover.isShown, "menu-bar popover did not open")
        guard let menuContent = shell.shellTestPopover.contentViewController?.view,
              let menuSettings = descendant(menuContent, identifier: "yuliang.settings.button") as? NSButton else {
            throw ShellCheckFailure(description: "visible menu-bar popover lost its explicit settings button")
        }
        try require(menuSettings.title == "设置" && menuSettings.isEnabled && menuSettings.bounds.width >= 36,
                    "menu-bar settings button lost its complete title or usable target")
        try require(panel.isVisible && model.desktopVisible, "opening popover hid the desktop card")
        model.positionLocked = true
        settle()
        try require(shell.shellTestSurfacesShareModel && !panel.isMovable && !panel.isMovableByWindowBackground,
                    "lock action from the shared popover model did not affect the desktop card")
        model.positionLocked = false
        settle()
        try require(panel.isMovable && panel.isMovableByWindowBackground, "shared popover model could not unlock the desktop card")
        try require(abs(shell.shellTestPopover.contentSize.width - expectedCardSize.width) <= 1,
                    "popover lost its fixed medium-widget width")
        try require(abs(shell.shellTestPopover.contentSize.height - expectedCardSize.height) <= 1,
                    "popover lost its fixed medium-widget height")
        model.onChooseCharacter?(.menuBar)
        settle(0.6)
        try require(shell.shellTestCharacterPopover.isShown
                    && isOnScreen(shell.shellTestCharacterPopover.contentViewController?.view.window),
                    "menu-bar character picker did not create a visible native window")
        shell.shellTestDismissCharacterPicker()
        settleUntil { !shell.shellTestCharacterPopover.isShown }
        try require(model.document.records == recordsBeforePicker, "character picker lifecycle mutated quota records")
        shell.shellTestTogglePopover()
        settle(0.6)
        try require(!shell.shellTestPopover.isShown, "second menu click failed to close popover")
        try require(panel.isVisible && model.desktopVisible, "closing popover changed desktop visibility")
        try require(ObjectIdentifier(model.collector) == collectorIdentity, "popover lifecycle replaced the collector")
        try require(!model.collector.isRunning && !model.collector.isBusy && model.collector.lastAttemptAt == nil,
                    "popover lifecycle changed collection state or triggered an account query")
        try require(shell.shellTestSurfacesShareModel, "surfaces lost their shared model after reopening")

        shell.shellTestTogglePopover()
        settle(0.6)
        shell.shellTestPopover.performClose(nil)
        settle(0.6)
        try require(!shell.shellTestPopover.isShown && panel.isVisible, "normal popover dismissal affected desktop card")
        model.desktopVisible = false
        settle()
        try require(!panel.isVisible && !model.collector.isRunning, "last card hiding should only affect visibility")
        try require(!model.claudeCollector.isRunning && !model.claudeCollector.isBusy
                    && model.claudeCollector.lastAttemptAt == nil && model.claudeCollector.webView.url == nil,
                    "desktop shell lifecycle unexpectedly started Claude login or collection")
    }
}
