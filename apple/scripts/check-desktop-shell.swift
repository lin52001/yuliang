// Compile with -D YULIANG_STANDALONE -D QUOTA_SHELL_TESTING alongside
// Shared/QuotaCard.swift and the standalone app sources. This harness opens
// only its own short-lived AppKit surfaces, uses a temporary store, and never
// starts the collector or reads Codex credentials.
import AppKit
import CoreGraphics
import Foundation
import QuotaCore

private struct ShellCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct DesktopShellCheck {
    @MainActor
    static func main() {
        do {
            try runChecks()
            print("PASS desktop shell: borderless, shared model, free drag/position lock, popover lifecycle, fitting size, desktop level, hide/recall; collector stayed paused")
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
    private static func runChecks() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yuliang-desktop-shell-check-\(UUID().uuidString)", isDirectory: true)
        let model = StandaloneModel(store: StandaloneQuotaStore(directory: directory))
        let shell = StandaloneAppDelegate()
        shell.prepareForShellTesting(model: model)
        defer {
            shell.shellTestTearDown()
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
        try require(model.desktopVisible && panel.isVisible, "desktop card cannot be shown")
        try require(panel.level == .floating, "default desktop card should be floating")
        let compactHeight = panel.frame.height
        try require(panel.frame.width == 320 && compactHeight >= 160 && compactHeight < 380, "compact card has an invalid fitting size")
        let unlockedFrame = panel.frame
        model.positionLocked = true
        settle()
        try require(!panel.isMovable && !panel.isMovableByWindowBackground, "position lock did not disable AppKit dragging")
        try require(panel.frame == unlockedFrame, "locking unexpectedly moved the remembered card position")
        try require(panel.level == .floating, "position lock changed the independent floating preference")
        model.positionLocked = false
        settle()
        try require(panel.isMovable && panel.isMovableByWindowBackground, "unlocking did not restore AppKit dragging")
        try require(panel.frame == unlockedFrame, "unlocking unexpectedly moved the remembered card position")
        model.compact = false
        settle()
        shell.shellTestResize()
        try require(panel.frame.height >= compactHeight, "expanded card clipped instead of growing")
        model.compact = true
        settle()
        shell.shellTestResize()
        try require(abs(panel.frame.height - compactHeight) <= 1, "compact size failed to restore")

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
        try require(panel.isVisible && model.desktopVisible, "opening popover hid the desktop card")
        model.positionLocked = true
        settle()
        try require(shell.shellTestSurfacesShareModel && !panel.isMovable && !panel.isMovableByWindowBackground,
                    "lock action from the shared popover model did not affect the desktop card")
        model.positionLocked = false
        settle()
        try require(panel.isMovable && panel.isMovableByWindowBackground, "shared popover model could not unlock the desktop card")
        try require(abs(shell.shellTestPopover.contentSize.width - 320) <= 1, "popover width is not compact")
        try require(shell.shellTestPopover.contentSize.height >= 160 && shell.shellTestPopover.contentSize.height < 380, "popover has an invalid fitting height")
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
    }
}
