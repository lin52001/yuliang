import AppKit
import SwiftUI
import Combine
import CoreGraphics
import QuotaCore

final class QuotaFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performDrag(with event: NSEvent) {
        guard isMovable && isMovableByWindowBackground else { return }
        super.performDrag(with: event)
    }
}

/// One view model and collector power both surfaces. Closing either surface
/// affects presentation only; automatic quota collection belongs to the app.
@MainActor
final class StandaloneAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var model: StandaloneModel!
    private var panel: QuotaFloatingPanel!
    private var desktopHost: NSHostingView<DesktopCardChrome>!
    private var popoverHost: NSHostingController<MenuBarCardChrome>!
    private var popover: NSPopover!
    private var characterHost: NSHostingController<CharacterPickerChrome>!
    private var characterPopover: NSPopover!
    private var browser: NSWindow?
    private var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var resizeScheduled = false
    private var lastStatusSignature: String?
    private let frameName = NSWindow.FrameAutosaveName("YuliangDesktopCardV1")
    private var persistsPreferences = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        configure(model: StandaloneModel(), startCollector: true, showOnLaunch: true)
    }

    private func configure(model: StandaloneModel, startCollector: Bool, showOnLaunch: Bool) {
        self.model = model
        if persistsPreferences {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "card.pinned") != nil { model.pinned = defaults.bool(forKey: "card.pinned") }
            if defaults.object(forKey: "card.compact") != nil { model.compact = defaults.bool(forKey: "card.compact") }
            if defaults.object(forKey: "card.positionLocked") != nil { model.positionLocked = defaults.bool(forKey: "card.positionLocked") }
            if defaults.object(forKey: "display.dailyTokens") != nil { model.showDailyTokens = defaults.bool(forKey: "display.dailyTokens") }
            if defaults.object(forKey: "display.lifetimeTokens") != nil { model.showLifetimeTokens = defaults.bool(forKey: "display.lifetimeTokens") }
            if let raw = defaults.string(forKey: "card.appearance"), let appearance = StandaloneAppearance(rawValue: raw) { model.appearance = appearance }
            if let raw = defaults.string(forKey: "card.displayStyle"), let style = StandaloneDisplayStyle(rawValue: raw) { model.displayStyle = style }
        }
        panel = QuotaFloatingPanel(contentRect: NSRect(x: 0, y: 0,
                                                     width: StandaloneLayout.desktopWidth(style: model.displayStyle, compact: model.compact),
                                                     height: 180),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "余量 · 桌面卡片"
        panel.appearance = model.appearance.nativeAppearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        desktopHost = NSHostingView(rootView: DesktopCardChrome(model: model))
        desktopHost.wantsLayer = true
        desktopHost.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = desktopHost
        resizeSurfaces()
        placeOnCurrentScreen()
        if persistsPreferences {
            panel.setFrameAutosaveName(frameName)
            if panel.setFrameUsingName(frameName) { keepCardOnScreen() }
        }
        applyPin(model.pinned)
        applyPositionLock(model.positionLocked)

        popoverHost = NSHostingController(rootView: MenuBarCardChrome(model: model))
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = model.appearance.nativeAppearance
        popover.contentViewController = popoverHost
        popover.delegate = self

        characterHost = NSHostingController(rootView: CharacterPickerChrome(model: model) { [weak self] in
            self?.characterPopover.close()
        })
        characterPopover = NSPopover()
        characterPopover.behavior = .transient
        characterPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        characterPopover.appearance = model.appearance.nativeAppearance
        characterPopover.contentViewController = characterHost

        model.onConnect = { [weak self] in self?.openConnection() }
        model.onChooseCharacter = { [weak self] surface in self?.chooseCharacter(from: surface) }
        model.onPin = { [weak self] pinned in
            self?.applyPin(pinned)
            self?.savePreference(pinned, key: "card.pinned")
        }
        model.onPositionLock = { [weak self] locked in
            self?.applyPositionLock(locked)
            self?.savePreference(locked, key: "card.positionLocked")
        }
        model.onResize = { [weak self] compact in
            self?.scheduleResize()
            self?.savePreference(compact, key: "card.compact")
        }
        model.onDesktopVisibility = { [weak self] visible in self?.setDesktopVisible(visible) }
        model.onShowDesktop = { [weak self] in self?.showDesktop(reposition: true) }
        model.onDisplayChange = { [weak self] in
            guard let self else { return }
            self.savePreference(self.model.showDailyTokens, key: "display.dailyTokens")
            self.savePreference(self.model.showLifetimeTokens, key: "display.lifetimeTokens")
            self.scheduleResize()
        }
        model.onAppearance = { [weak self] appearance in
            guard let self else { return }
            self.applyAppearance(appearance)
            if self.persistsPreferences { UserDefaults.standard.set(appearance.rawValue, forKey: "card.appearance") }
        }
        model.onStyleChange = { [weak self] in
            guard let self else { return }
            self.characterPopover?.close()
            if self.persistsPreferences {
                UserDefaults.standard.set(self.model.displayStyle.rawValue, forKey: "card.displayStyle")
            }
            self.updateStatusItem()
            self.scheduleResize()
        }
        applyAppearance(model.appearance)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        model.$document.sink { [weak self] document in
            self?.updateStatusItem(document: document)
            self?.scheduleResize()
        }.store(in: &subscriptions)
        model.$now.sink { [weak self] date in
            self?.updateStatusItem(now: date)
        }.store(in: &subscriptions)
        model.$error.sink { [weak self] _ in self?.scheduleResize() }.store(in: &subscriptions)
        model.collector.$status.sink { [weak self] _ in self?.scheduleResize() }.store(in: &subscriptions)
        model.collector.$tokenUsage.sink { [weak self] _ in self?.scheduleResize() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: StandaloneMenuTracking.didEnd).sink { [weak self] _ in
            self?.updateStatusItem()
            self?.scheduleResize()
        }.store(in: &subscriptions)
        createMenu()
        if showOnLaunch { showDesktop(reposition: false) }
        else { model.desktopVisible = false }
        if startCollector { model.collector.start() }
        scheduleResize()
    }

    private func savePreference(_ value: Bool, key: String) {
        if persistsPreferences { UserDefaults.standard.set(value, forKey: key) }
    }

    private func updateStatusItem(document: QuotaStoreDocument? = nil, now: Date? = nil) {
        guard let statusItem else { return }
        let value = QuotaPresentation(document: document ?? model.document, now: now ?? model.now)
        let percent = value.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "未知"
        let reading: String
        switch value.freshness {
        case .fresh: reading = value.remainingPercent == nil ? "额度未提供" : "剩余 \(percent)"
        case .missing: reading = "等待读取额度"
        case .stale: reading = "上次剩余 \(percent) · 记录已陈旧"
        case .resetDue: reading = "上次剩余 \(percent) · 重置待核对"
        }
        let updated = value.observedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "尚未读取"
        let tooltip = "余量 · Codex\n\(value.window?.label ?? "订阅额度") · \(reading)\n额度更新 \(updated)\n点击查看用量与操作"
        let signature = "\(model.displayStyle.rawValue)/\(tooltip)"
        guard signature != lastStatusSignature else { return }
        // A fixed/variable-length transition may cause AppKit to refresh the
        // status button. Obtain its current instance after changing the item.
        let length = model.displayStyle == .duo ? CGFloat(24) : NSStatusItem.variableLength
        if statusItem.length != length { statusItem.length = length }
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip
        button.setAccessibilityLabel("余量，Codex，\(reading)，点击查看用量与操作")
        if model.displayStyle == .duo {
            button.imagePosition = .imageOnly
            button.title = ""
            button.image = Self.statusRingImage(remaining: value.remainingPercent,
                                                fresh: value.freshness == .fresh)
        } else {
            button.imagePosition = .noImage
            button.image = nil
            button.title = value.remainingPercent.map { "余 \(Int($0.rounded()))%" } ?? "余量"
        }
        lastStatusSignature = signature
        #if QUOTA_SHELL_TESTING
        print("Shell status style=\(model.displayStyle.rawValue) hasTitle=\(!button.title.isEmpty) hasImage=\(button.image != nil) imagePosition=\(button.imagePosition.rawValue)")
        #endif
    }

    /// An authored quota glyph. It represents quota only, never device battery
    /// or network status. Template rendering follows the actual menu-bar theme.
    private static func statusRingImage(remaining: Double?, fresh: Bool) -> NSImage {
        let known = remaining.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { bounds in
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius: CGFloat = 7.5
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
            ring.lineWidth = 1.6
            NSColor.black.withAlphaComponent(known == nil ? 0.5 : 0.22).setStroke()
            if known == nil { ring.setLineDash([1.3, 1.8], count: 2, phase: 0) }
            ring.stroke()
            if let known, known > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                if !fresh { arc.setLineDash([2.2, 1.8], count: 2, phase: 0) }
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: CGFloat(90 - known * 3.6), clockwise: true)
                NSColor.black.setStroke()
                arc.stroke()
            }
            let text = known.map { String(Int($0.rounded())) } ?? "?"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
            let label = NSAttributedString(string: text, attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex 剩余额度"
        return image
    }

    private func applyAppearance(_ appearance: StandaloneAppearance) {
        NSApp.appearance = appearance.nativeAppearance
        panel?.appearance = appearance.nativeAppearance
        popover?.appearance = appearance.nativeAppearance
        characterPopover?.appearance = appearance.nativeAppearance
        browser?.appearance = appearance.nativeAppearance
        scheduleResize()
    }

    private func applyPin(_ pinned: Bool) {
        guard let panel else { return }
        panel.level = pinned ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    private func applyPositionLock(_ locked: Bool) {
        guard let panel else { return }
        panel.isMovable = !locked
        panel.isMovableByWindowBackground = !locked
    }

    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeSurfaces()
        }
    }

    private func resizeSurfaces() {
        // Settings live in an independent panel; widget geometry can update
        // without replacing a menu anchor or closing the settings surface.
        if let desktopHost, let panel {
            desktopHost.layoutSubtreeIfNeeded()
            let fitting = desktopHost.fittingSize
            let old = panel.frame
            let size = NSSize(width: StandaloneLayout.desktopWidth(style: model.displayStyle, compact: model.compact),
                              height: max(StandaloneLayout.minimumHeight(style: model.displayStyle), ceil(fitting.height)))
            if abs(old.height - size.height) > 0.5 || old.width != size.width {
                panel.setContentSize(size)
                panel.setFrameOrigin(NSPoint(x: old.minX, y: old.maxY - size.height))
                keepCardOnScreen()
                if persistsPreferences, panel.frameAutosaveName != NSWindow.FrameAutosaveName("") {
                    panel.saveFrame(usingName: panel.frameAutosaveName)
                }
            }
        }
        if let popoverHost, let popover {
            popoverHost.view.layoutSubtreeIfNeeded()
            let fitting = popoverHost.view.fittingSize
            popover.contentSize = NSSize(width: StandaloneLayout.cardWidth(compact: model.compact),
                                        height: max(StandaloneLayout.minimumHeight(style: .card), ceil(fitting.height)))
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func placeOnCurrentScreen() {
        guard let panel, let screen = targetScreen() else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24,
                                     y: screen.visibleFrame.maxY - panel.frame.height - 24))
    }

    private func keepCardOnScreen() {
        guard let panel, !NSScreen.screens.isEmpty else { return }
        let screen = NSScreen.screens.max { left, right in
            intersectionArea(left.visibleFrame, panel.frame) < intersectionArea(right.visibleFrame, panel.frame)
        } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let x = min(max(panel.frame.minX, visible.minX), max(visible.minX, visible.maxX - panel.frame.width))
        let y = min(max(panel.frame.minY, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let rect = a.intersection(b)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private func setDesktopVisible(_ visible: Bool) {
        guard let panel else { return }
        if visible { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }

    private func showDesktop(reposition: Bool) {
        popover?.performClose(nil)
        if reposition { placeOnCurrentScreen() }
        else { keepCardOnScreen() }
        model.desktopVisible = true
        panel.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDesktop(reposition: true)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        StandaloneSettingsPresenter.close()
        model?.collector.pause()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            resizeSurfaces()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    @objc private func showPanel() { showDesktop(reposition: true) }
    @objc private func connectAction() { openConnection() }
    @objc private func refreshAction() { model.collector.refreshNow() }

    private func chooseCharacter(from surface: StandaloneSurface) {
        if characterPopover.isShown { characterPopover.performClose(nil); return }
        let anchor: NSView
        if surface == .desktop {
            if !panel.isVisible { showDesktop(reposition: false) }
            anchor = desktopHost
        } else {
            if !popover.isShown { togglePopover() }
            anchor = popoverHost.view
        }
        // This is an explicit click. Activate before presenting a new native
        // popover so a nonactivating desktop panel cannot leave it AX-only.
        NSApp.activate(ignoringOtherApps: true)
        anchor.window?.makeKey()
        anchor.layoutSubtreeIfNeeded()
        characterHost.view.layoutSubtreeIfNeeded()
        characterPopover.contentSize = characterHost.view.fittingSize
        let buttonWidth = min(CGFloat(24), anchor.bounds.width)
        let buttonHeight = min(CGFloat(22), anchor.bounds.height)
        let x = max(anchor.bounds.minX, anchor.bounds.maxX - buttonWidth - 10)
        let desiredY = anchor.isFlipped ? anchor.bounds.maxY - buttonHeight - 6 : anchor.bounds.minY + 6
        let y = min(max(anchor.bounds.minY, desiredY), anchor.bounds.maxY - buttonHeight)
        let button = NSRect(x: x, y: y, width: buttonWidth, height: buttonHeight)
        characterPopover.show(relativeTo: button, of: anchor, preferredEdge: .maxX)
        characterHost.view.window?.makeKey()
    }

    private func openConnection() {
        popover.performClose(nil)
        if browser == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "余量 · 用量与额度"
            window.appearance = model.appearance.nativeAppearance
            window.contentView = NSHostingView(rootView: StandaloneConnectionView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            browser = window
        }
        browser?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "找回桌面卡片", action: #selector(showPanel), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "用量与额度详情", action: #selector(connectAction), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "立即刷新", action: #selector(refreshAction), keyEquivalent: "r").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出余量", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        menu.addItem(app)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    #if QUOTA_SHELL_TESTING
    /// Only available in an isolated test executable, never the shipped app.
    func prepareForShellTesting(model: StandaloneModel) {
        persistsPreferences = false
        configure(model: model, startCollector: false, showOnLaunch: false)
    }
    var shellTestConnectionWindow: NSWindow? { browser }
    var shellTestPanel: NSPanel { panel }
    var shellTestPopover: NSPopover { popover }
    var shellTestCharacterPopover: NSPopover { characterPopover }
    var shellTestCharacterPickerSharesModel: Bool { characterHost.rootView.model === model }
    var shellTestStatusButton: NSStatusBarButton? { statusItem.button }
    var shellTestSurfacesShareModel: Bool { desktopHost.rootView.model === model && popoverHost.rootView.model === model }
    func shellTestTogglePopover() { togglePopover() }
    func shellTestShowDesktop() { showDesktop(reposition: false) }
    func shellTestResize() { resizeSurfaces() }
    func shellTestDismissCharacterPicker() { characterHost.rootView.onSelect() }
    func shellTestTearDown() {
        StandaloneSettingsPresenter.close()
        characterPopover.performClose(nil)
        popover.performClose(nil)
        panel.orderOut(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
        subscriptions.removeAll()
    }
    #endif
}

private struct CharacterPickerChrome: View {
    @ObservedObject var model: StandaloneModel
    let onSelect: () -> Void
    var body: some View {
        StandaloneCharacterPicker(model: model, onSelect: onSelect)
            .preferredColorScheme(model.appearance.colorScheme)
            .background(QuotaPalette.surface)
    }
}

private struct DesktopCardChrome: View {
    @ObservedObject var model: StandaloneModel
    var body: some View {
        StandalonePanelView(model: model, surface: .desktop)
            .preferredColorScheme(model.appearance.colorScheme)
            .background(QuotaPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: model.displayStyle == .duo ? 24 : 18,
                                        style: .continuous))

    }
}

private struct MenuBarCardChrome: View {
    @ObservedObject var model: StandaloneModel
    var body: some View {
        StandalonePanelView(model: model, surface: .menuBar)
            .preferredColorScheme(model.appearance.colorScheme)
    }
}

#if !QUOTA_SHELL_TESTING
@main
struct YuliangStandaloneApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = StandaloneAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
