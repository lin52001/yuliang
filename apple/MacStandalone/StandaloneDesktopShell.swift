import AppKit
import SwiftUI
import Combine
import CoreGraphics
import QuartzCore
import QuotaCore

final class QuotaFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.36
    }

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
    private var claudeBrowser: NSWindow?
    private var petWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var subscriptions = Set<AnyCancellable>()
    private var resizeScheduled = false
    private var lastStatusSignature: String?
    private let frameName = NSWindow.FrameAutosaveName("YuliangDesktopCardV1")
    private var persistsPreferences = true
    private var pluginBridge: StandalonePluginBridge?

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
            if defaults.object(forKey: "buddy.companion") != nil { model.companionEnabled = defaults.bool(forKey: "buddy.companion") }
            if let raw = defaults.string(forKey: "card.appearance"), let appearance = StandaloneAppearance(rawValue: raw) { model.appearance = appearance }
            if let raw = defaults.string(forKey: "card.widgetColor"), let style = StandaloneWidgetColorStyle(rawValue: raw) { model.widgetColorStyle = style }
            if let raw = defaults.string(forKey: "card.displayStyle"), let style = StandaloneDisplayStyle(rawValue: raw) { model.displayStyle = style }
            if let raw = defaults.string(forKey: "display.language"), let language = YuliangLanguage(rawValue: raw) { model.language = language }
        }
        panel = QuotaFloatingPanel(contentRect: NSRect(x: 0, y: 0,
                                                     width: StandaloneLayout.desktopWidth(style: model.displayStyle, compact: model.compact),
                                                     height: 180),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = YuliangL10n.text("余量 · 桌面卡片")
        panel.appearance = model.appearance.nativeAppearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        desktopHost = NSHostingView(rootView: DesktopCardChrome(model: model))
        // AppKit owns the widget's fixed outer frame. SwiftUI intrinsic-size
        // updates must not resize the panel before we preserve its top anchor.
        desktopHost.sizingOptions = []
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
        model.onConnectClaude = { [weak self] in self?.openClaudeConnection() }
        model.onCompanionChange = { [weak self] enabled in self?.savePreference(enabled, key: "buddy.companion") }
        model.onChooseCharacter = { [weak self] surface in self?.chooseCharacter(from: surface) }
        model.onShowPet = { [weak self] surface in self?.openPet(from: surface) }
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
        model.onPluginShowDesktop = { [weak self] in self?.showDesktop(reposition: false) }
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
        model.onWidgetColorChange = { [weak self] style in
            guard let self, self.persistsPreferences else { return }
            UserDefaults.standard.set(style.rawValue, forKey: "card.widgetColor")
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
        model.onLanguageChange = { [weak self] language in
            guard let self else { return }
            self.transitionSurfaces()
            if self.persistsPreferences { UserDefaults.standard.set(language.rawValue, forKey: "display.language") }
            self.panel?.title = YuliangL10n.text("余量 · 桌面卡片")
            self.browser?.title = YuliangL10n.text("余量 · 用量与额度")
            self.claudeBrowser?.title = YuliangL10n.text("余量 · 连接 Claude")
            self.petWindow?.title = PetUI.text("余量 · 伙伴成长", "Yuliang · Buddy", "余量 · 仲間の成長", language: language)
            self.lastStatusSignature = nil
            self.updateStatusItem()
            self.createMenu()
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
        model.claudeCollector.$status.sink { [weak self] _ in self?.scheduleResize() }.store(in: &subscriptions)
        let workspaceEvents = NSWorkspace.shared.notificationCenter
        updateDesktopEmphasis()
        workspaceEvents.publisher(for: NSWorkspace.didActivateApplicationNotification).sink { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateDesktopEmphasis(frontmost: app)
        }.store(in: &subscriptions)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceEvents.publisher(for: name).sink { [weak self] _ in self?.model.companionSleeping = true }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceEvents.publisher(for: name).sink { [weak self] _ in self?.model.companionSleeping = false }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: StandaloneMenuTracking.didEnd).sink { [weak self] _ in
            self?.updateStatusItem()
            self?.scheduleResize()
        }.store(in: &subscriptions)
        createMenu()
        if showOnLaunch { showDesktop(reposition: false) }
        else { model.desktopVisible = false }
        if startCollector { model.collector.start() }
        #if !QUOTA_SHELL_TESTING
        // The bridge reuses this exact model and its existing 60-second collectors.
        // A failure to create its private local queue never blocks the widget.
        let bridge = StandalonePluginBridge(model: model)
        do { try bridge.start(); pluginBridge = bridge }
        catch { bridge.stop() }
        #endif
        scheduleResize()
    }

    private func savePreference(_ value: Bool, key: String) {
        if persistsPreferences { UserDefaults.standard.set(value, forKey: key) }
    }

    private func updateDesktopEmphasis(frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let frontmost else { return }
        model.desktopIsForeground = frontmost.bundleIdentifier == "com.apple.finder"
            || frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func updateStatusItem(document: QuotaStoreDocument? = nil, now: Date? = nil) {
        guard let statusItem else { return }
        let value = QuotaPresentation(document: document ?? model.document, now: now ?? model.now)
        let percent = value.remainingPercent.map { "\(Int($0.rounded()))%" } ?? YuliangL10n.text("未知")
        let reading: String
        switch value.freshness {
        case .fresh: reading = value.remainingPercent == nil ? YuliangL10n.text("额度未提供") : YuliangL10n.format("剩余 {0}", percent)
        case .missing: reading = YuliangL10n.text("等待读取额度")
        case .stale: reading = YuliangL10n.format("上次剩余 {0} · 记录已陈旧", percent)
        case .resetDue: reading = YuliangL10n.format("上次剩余 {0} · 重置待核对", percent)
        }
        let updated = value.observedAt.map { StandaloneDateFormat.string($0, dateStyle: .abbreviated, timeStyle: .standard) } ?? YuliangL10n.text("尚未读取")
        let tooltip = YuliangL10n.text("余量 · ") + value.provider.name + "\n" + YuliangL10n.text(value.window?.label ?? YuliangL10n.text("订阅额度")) + " · " + reading + "\n" + YuliangL10n.text("额度更新 ") + updated + "\n" + YuliangL10n.text("点击查看用量与操作")
        let signature = "\(model.displayStyle.rawValue)/\(tooltip)"
        guard signature != lastStatusSignature else { return }
        // A fixed/variable-length transition may cause AppKit to refresh the
        // status button. Obtain its current instance after changing the item.
        let length = model.displayStyle == .duo ? CGFloat(24) : NSStatusItem.variableLength
        if statusItem.length != length { statusItem.length = length }
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip
        button.setAccessibilityLabel(YuliangL10n.text("余量 · ") + value.provider.name + " · " + reading + " · " + YuliangL10n.text("点击查看用量与操作"))
        if model.displayStyle == .duo {
            button.imagePosition = .imageOnly
            button.title = ""
            button.image = Self.statusRingImage(remaining: value.remainingPercent,
                                                fresh: value.freshness == .fresh)
        } else {
            button.imagePosition = .noImage
            button.image = nil
            button.title = value.remainingPercent.map { YuliangL10n.format("余 {0}%", String(Int($0.rounded()))) } ?? YuliangL10n.text("余量")
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
        image.accessibilityDescription = YuliangL10n.text("订阅剩余额度")
        return image
    }

    private func applyAppearance(_ appearance: StandaloneAppearance) {
        transitionSurfaces()
        NSApp.appearance = appearance.nativeAppearance
        panel?.appearance = appearance.nativeAppearance
        popover?.appearance = appearance.nativeAppearance
        characterPopover?.appearance = appearance.nativeAppearance
        browser?.appearance = appearance.nativeAppearance
        claudeBrowser?.appearance = appearance.nativeAppearance
        petWindow?.appearance = appearance.nativeAppearance
        scheduleResize()
    }

    private func transitionSurfaces() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for window in [panel, browser, claudeBrowser, petWindow, popover?.contentViewController?.view.window, characterPopover?.contentViewController?.view.window].compactMap({ $0 }) {
            guard window.isVisible, let view = window.contentView else { continue }
            view.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.layer?.add(fade, forKey: "widget.appearance")
        }
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
            let old = panel.frame
            let size = NSSize(width: StandaloneLayout.desktopWidth(style: model.displayStyle, compact: model.compact),
                              height: StandaloneLayout.desktopHeight(style: model.displayStyle, compact: model.compact))
            if abs(old.height - size.height) > 0.5 || old.width != size.width {
                var target = NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height)
                if let visible = NSScreen.screens.max(by: { intersectionArea($0.visibleFrame, old) < intersectionArea($1.visibleFrame, old) })?.visibleFrame {
                    target.origin.x = min(max(target.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
                    target.origin.y = min(max(target.minY, visible.minY), max(visible.minY, visible.maxY - size.height))
                }
                #if QUOTA_SHELL_TESTING
                let animate = false
                #else
                let animate = panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                #endif
                panel.setFrame(target, display: true, animate: animate)
                if persistsPreferences, panel.frameAutosaveName != NSWindow.FrameAutosaveName("") {
                    panel.saveFrame(usingName: panel.frameAutosaveName)
                }
            }
            else { keepCardOnScreen() }
        }
        if let popoverHost, let popover {
            popoverHost.view.layoutSubtreeIfNeeded()
            popover.contentSize = NSSize(width: StandaloneLayout.cardWidth(compact: model.compact),
                                        height: StandaloneLayout.cardHeight(compact: model.compact))
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
        model.companionVisible = visible || (popover?.isShown ?? false)
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
        pluginBridge?.stop()
        pluginBridge = nil
        StandaloneSettingsPresenter.close()
        model?.collector.pause()
        model?.claudeCollector.pause()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            resizeSurfaces()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
        model.companionVisible = panel.isVisible || popover.isShown
    }
    func popoverDidShow(_ notification: Notification) { model.companionVisible = panel.isVisible || popover.isShown }
    func popoverDidClose(_ notification: Notification) { model.companionVisible = panel.isVisible || popover.isShown }
    @objc private func showPanel() { showDesktop(reposition: true) }
    @objc private func connectAction() { openConnection() }
    @objc private func refreshAction() { model.refreshSelected() }
    @objc private func petAction() { openPet(from: .desktop) }

    private func openPet(from surface: StandaloneSurface) {
        StandaloneSettingsPresenter.close()
        characterPopover.performClose(nil)
        if petWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("yuliang.pet.window")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: StandalonePetView(model: model))
            petWindow = window
        }
        guard let window = petWindow else { return }
        window.title = PetUI.text("余量 · 伙伴成长", "Yuliang · Buddy", "余量 · 仲間の成長", language: model.language)
        window.appearance = model.appearance.nativeAppearance
        let anchor = surface == .desktop ? panel.frame : (popoverHost.view.window?.frame ?? panel.frame)
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame
        if let visible {
            let x = anchor.maxX + 8 + 400 <= visible.maxX ? anchor.maxX + 8 : anchor.minX - 408
            window.setFrameOrigin(NSPoint(x: max(visible.minX, min(x, visible.maxX - 400)),
                y: max(visible.minY, min(anchor.maxY - window.frame.height, visible.maxY - window.frame.height))))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 566),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = YuliangL10n.text("余量 · 用量与额度")
            window.appearance = model.appearance.nativeAppearance
            window.contentView = NSHostingView(rootView: StandaloneConnectionRootView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            browser = window
        }
        browser?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openClaudeConnection() {
        model.selectProvider(.claude)
        if claudeBrowser == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = YuliangL10n.text("余量 · 连接 Claude")
            window.appearance = model.appearance.nativeAppearance
            window.contentView = NSHostingView(rootView: ClaudeConnectionView(collector: model.claudeCollector))
            window.minSize = NSSize(width: 740, height: 620)
            window.isReleasedWhenClosed = false
            window.center()
            claudeBrowser = window
        }
        claudeBrowser?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: YuliangL10n.text("找回桌面卡片"), action: #selector(showPanel), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: YuliangL10n.text("用量与额度详情"), action: #selector(connectAction), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: YuliangL10n.text("立即刷新"), action: #selector(refreshAction), keyEquivalent: "r").target = self
        appMenu.addItem(withTitle: PetUI.text("伙伴成长与收藏", "Buddy care & collection", "仲間の成長とコレクション", language: model.language), action: #selector(petAction), keyEquivalent: "p").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: YuliangL10n.text("退出余量"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        menu.addItem(app)
        let edit = NSMenuItem(title: YuliangL10n.text("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: YuliangL10n.text("编辑"))
        for (title, action, key) in [(YuliangL10n.text("撤销"), "undo:", "z"), (YuliangL10n.text("剪切"), "cut:", "x"), (YuliangL10n.text("复制"), "copy:", "c"), (YuliangL10n.text("粘贴"), "paste:", "v"), (YuliangL10n.text("全选"), "selectAll:", "a")] {
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
    var shellTestPetWindow: NSWindow? { petWindow }
    func shellTestShowPet() { openPet(from: .desktop) }
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
        petWindow?.close()
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
            .background(StandalonePalette.surface)
    }
}

private struct DesktopCardChrome: View {
    @ObservedObject var model: StandaloneModel
    var body: some View {
        StandalonePanelView(model: model, surface: .desktop)
            .preferredColorScheme(model.appearance.colorScheme)
            .clipShape(RoundedRectangle(cornerRadius: StandaloneLayout.cornerRadius(style: model.displayStyle, compact: model.compact),
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
