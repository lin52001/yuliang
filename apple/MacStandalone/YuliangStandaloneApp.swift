import AppKit
import SwiftUI
import Combine
import QuotaCore

enum StandaloneAppearance: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
    var nativeAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

enum StandaloneDisplayStyle: String, CaseIterable {
    case card, duo
    var label: String { self == .card ? "轻巧卡片" : "Duo 圆环" }
}

/// Desktop emphasis is separate from light/dark appearance, as it is for
/// macOS widgets. This is a public AppKit approximation of desktop rendering.
enum StandaloneWidgetColorStyle: String, CaseIterable {
    case automatic, fullColor, monochrome
    var label: String {
        switch self {
        case .automatic: return "自动 · 后台淡为单色"
        case .fullColor: return "始终全彩"
        case .monochrome: return "始终单色"
        }
    }
    func isMonochrome(desktopIsForeground: Bool) -> Bool {
        self == .monochrome || (self == .automatic && !desktopIsForeground)
    }
}

private struct StandaloneWidgetMaterial: NSViewRepresentable {
    let emphasized: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("yuliang.widget.material")
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // A nonactivating desktop panel never becomes the key window. Drive
        // material state from desktop emphasis instead of its key status.
        view.state = emphasized ? .active : .inactive
    }
}

enum StandaloneLayout {
    static let cornerRadius: CGFloat = 22
    static let height: CGFloat = 160
    static func cardWidth(compact: Bool) -> CGFloat { 344 }
    static func desktopWidth(style: StandaloneDisplayStyle, compact: Bool) -> CGFloat {
        style == .duo ? 160 : cardWidth(compact: compact)
    }
    static func minimumHeight(style: StandaloneDisplayStyle) -> CGFloat { height }
}

enum TokenUsageFormat {
    static func compact(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let units: [(Int64, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        for (divisor, suffix) in units where value >= divisor {
            return String(format: "%.1f", Double(value) / Double(divisor)) + suffix
        }
        return String(value)
    }
    static func exact(_ value: Int64?) -> String { value.map { $0.formatted() + " Token" } ?? "未提供" }
    static func day(_ value: String?) -> String { value.map { String($0.suffix(5)).replacingOccurrences(of: "-", with: "/") } ?? "未提供日期" }
}

@MainActor
final class StandaloneModel: ObservableObject {
    @Published var document = QuotaStoreDocument()
    @Published var error: String?
    @Published var now = Date()
    @Published var animateQuota = false
    @Published var compact = true { didSet { onResize?(compact) } }
    @Published var pinned = true { didSet { onPin?(pinned) } }
    @Published var positionLocked = false { didSet { onPositionLock?(positionLocked) } }
    @Published var desktopVisible = true { didSet { onDesktopVisibility?(desktopVisible) } }
    @Published var showDailyTokens = true { didSet { onDisplayChange?() } }
    @Published var showLifetimeTokens = true { didSet { onDisplayChange?() } }
    @Published var appearance = StandaloneAppearance.system { didSet { onAppearance?(appearance) } }
    @Published var widgetColorStyle = StandaloneWidgetColorStyle.automatic { didSet { onWidgetColorChange?(widgetColorStyle) } }
    @Published var desktopIsForeground = true
    @Published var displayStyle = StandaloneDisplayStyle.card { didSet { onStyleChange?() } }
    @Published var buddyActivity: BuddyActivity?
    @Published var buddyFeedback = BuddyFeedbackState()
    @Published var companionEnabled = true { didSet { onCompanionChange?(companionEnabled) } }
    var companionVisible = true
    var companionSleeping = false
    private var companionSchedule = BuddyCompanionSchedule()
    #if QUOTA_SHELL_TESTING
    private var companionReduceMotionOverride: Bool?
    func shellTestResetCompanion(now: Date, seed: UInt64, reduceMotion: Bool = false) {
        companionSchedule = BuddyCompanionSchedule(now: now, seed: seed)
        companionReduceMotionOverride = reduceMotion
    }
    func shellTestReceiveSnapshot(_ snapshot: SnapshotEnvelope, now: Date) throws {
        try receive(snapshot, now: now)
    }
    #endif
    private var companionReduceMotion: Bool {
        #if QUOTA_SHELL_TESTING
        if let override = companionReduceMotionOverride { return override }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var clock: AnyCancellable?
    private var feedbackTransition: DispatchWorkItem?
    private var lastPlay: BuddyAction = .idle
    let collector: CodexQuotaCollector
    let claudeCollector: QuotaWebCollector
    let store: StandaloneQuotaStore
    var onConnect: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onCompanionChange: ((Bool) -> Void)?
    var onChooseCharacter: ((StandaloneSurface) -> Void)?
    var onResize: ((Bool) -> Void)?
    var onPin: ((Bool) -> Void)?
    var onPositionLock: ((Bool) -> Void)?
    var onDesktopVisibility: ((Bool) -> Void)?
    var onShowDesktop: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onAppearance: ((StandaloneAppearance) -> Void)?
    var onWidgetColorChange: ((StandaloneWidgetColorStyle) -> Void)?
    var onStyleChange: (() -> Void)?

    init(store: StandaloneQuotaStore = .shared) {
        self.store = store
        self.collector = CodexQuotaCollector()
        self.claudeCollector = QuotaWebCollector()
        do { document = try store.read() }
        catch { self.error = error.localizedDescription }
        if !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("quota.json").path)
            || ![QuotaProvider.codex, .claude].contains(document.preferences.providerId) {
            do {
                try store.updatePreferences { $0.providerId = .codex; $0.windowId = nil }
                document = try store.read()
            } catch { self.error = error.localizedDescription }
        }
        // Old private themes remain readable, but a public build without their
        // optional artwork starts with an available character instead.
        if !availableCharacters.contains(document.preferences.character) {
            do {
                try store.updatePreferences { $0.character = .dragonGirl }
                document = try store.read()
            } catch { self.error = error.localizedDescription }
        }
        buddyFeedback = BuddyFeedbackState(observedAt: QuotaPresentation(document: document).observedAt)
        collector.onSnapshot = { [weak self] snapshot in
            try self?.receive(snapshot)
        }
        claudeCollector.onSnapshot = { [weak self] snapshot in try self?.receive(snapshot) }
        clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            self?.advanceClock(to: date)
        }
    }
    private func receive(_ snapshot: SnapshotEnvelope, now receivedAt: Date = Date()) throws {
        let previous = QuotaPresentation(document: document, now: receivedAt)
        let changed = try store.ingest(snapshot)
        let latest = try store.read()
        let next = QuotaPresentation(document: latest, now: receivedAt)
        let selected = snapshot.providerId == next.provider
        if selected {
            animateQuota = previous.provider == next.provider && previous.window?.id == next.window?.id
                && previous.freshness == .fresh && next.freshness == .fresh
                && previous.remainingPercent != nil && next.remainingPercent != nil
                && previous.remainingPercent != next.remainingPercent
                && (next.observedAt ?? .distantPast) > (previous.observedAt ?? .distantFuture)
        }
        document = latest
        now = receivedAt
        guard selected, changed else { return }
        if let observedAt = next.observedAt {
            buddyFeedback.didRefresh(observedAt: observedAt, now: now)
            scheduleFeedbackTransition()
        }
        if let consumed = BuddyQuotaChange.consumption(from: previous, to: next) {
            buddyActivity = BuddyActivity(action: .eating, startedAt: now, source: .usage, consumedPercent: consumed)
            // The shared clock protects eating via its busy context and a short
            // quiet interval. Resetting the whole idle deadline every 60-second
            // consumption observation would prevent all autonomous company.
        }
        error = nil
    }
    func advanceClock(to date: Date) {
        now = date
        if let activity = buddyActivity, date.timeIntervalSince(activity.startedAt) >= activity.duration { buddyActivity = nil }
        let context = BuddyCompanionContext(isVisible: companionVisible,
            isBusy: buddyActivity != nil || StandaloneMenuTracking.isActive,
            isSleeping: companionSleeping, reduceMotion: companionReduceMotion,
            isEnabled: companionEnabled)
        if let moment = companionSchedule.tick(now: date, context: context), buddyFeedback.accompany(moment, now: date) {
            buddyActivity = BuddyActivity(action: moment.action, startedAt: date, source: .companion)
            scheduleFeedbackTransition()
        }
    }
    func selectProvider(_ provider: QuotaProvider) {
        guard [.codex, .claude].contains(provider), provider != document.preferences.providerId else { return }
        preference { $0.providerId = provider; $0.windowId = nil }
        buddyFeedback = BuddyFeedbackState(observedAt: QuotaPresentation(document: document, now: now).observedAt)
        companionSchedule.postpone(after: now)
    }
    func refreshSelected() {
        if document.preferences.providerId == .claude { claudeCollector.refreshNow() }
        else { collector.refreshNow() }
    }
    var selectedBusy: Bool { document.preferences.providerId == .claude ? claudeCollector.isBusy : collector.isBusy }
    var selectedQuotaError: String? { document.preferences.providerId == .claude ? claudeCollector.lastError : collector.quotaError }
    func preference(_ action: (inout QuotaPreferences) -> Void) {
        animateQuota = false
        do {
            let previous = QuotaPresentation(document: document, now: now)
            try store.updatePreferences(action)
            document = try store.read()
            let selected = QuotaPresentation(document: document, now: now)
            if previous.provider != selected.provider || previous.window?.id != selected.window?.id { buddyActivity = nil }
            now = Date()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func pat() {
        let choices = BuddyAction.playfulActions.filter { $0 != lastPlay }
        let action = choices.randomElement() ?? .pat
        play(action)
    }
    func play(_ action: BuddyAction) {
        guard !isEatingUsage, action != .idle else { return }
        lastPlay = action
        now = Date()
        buddyActivity = BuddyActivity(action: action, startedAt: now, source: .play)
        buddyFeedback.interact(action, now: now)
        companionSchedule.postpone(after: now)
        scheduleFeedbackTransition()
    }
    func feed() { play(.eating) }
    var availableCharacters: [QuotaCharacter] {
        let legacy: [QuotaCharacter] = Bundle.main.url(forResource: "anime-satiety-atlas-v1", withExtension: "png") == nil
            ? [] : [.kuromi, .myMelody]
        return QuotaCharacter.builtInCharacters + legacy
    }
    func selectCharacter(_ character: QuotaCharacter) {
        guard availableCharacters.contains(character), character != document.preferences.character else { return }
        let eating = isEatingUsage ? buddyActivity : nil
        preference { $0.character = character }
        guard document.preferences.character == character else { return }
        buddyActivity = eating ?? BuddyActivity(action: .wave, startedAt: Date(), source: .play)
        if eating == nil {
            now = Date()
            buddyFeedback.interact(.wave, now: now)
            companionSchedule.postpone(after: now)
            scheduleFeedbackTransition()
        }
    }
    func switchCharacter() {
        let index = availableCharacters.firstIndex(of: document.preferences.character) ?? -1
        selectCharacter(availableCharacters[(index + 1) % availableCharacters.count])
    }
    var isEatingUsage: Bool {
        guard let activity = buddyActivity else { return false }
        return activity.action == .eating && activity.source == .usage && Date().timeIntervalSince(activity.startedAt) < activity.duration
    }
    var feedbackMessage: BuddyFeedbackMessage {
        let value = QuotaPresentation(document: document, now: now)
        let issue: String?
        if error != nil { issue = "读取失败，点此查看" }
        else if value.provider == .codex && collector.needsLogin { issue = "请先登录 Codex" }
        else if value.provider == .claude && claudeCollector.needsLogin { issue = "请先连接 Claude" }
        else if selectedQuotaError != nil { issue = "额度读取失败，点此查看" }
        else {
            switch value.freshness {
            case .missing: issue = value.provider == .claude ? "连接 Claude 额度" : "等待读取 Codex 额度"
            case .stale: issue = "上次额度已陈旧，点此查看"
            case .resetDue: issue = "额度重置待核对"
            case .fresh: issue = value.remainingPercent == nil ? "官方未提供额度比例" : nil
            }
        }
        return buddyFeedback.message(at: now,
                                     refreshTimeLabel: value.observedAt?.formatted(date: .omitted, time: .standard) ?? "",
                                     error: issue)
    }
    private func scheduleFeedbackTransition() {
        feedbackTransition?.cancel()
        guard let deadline = buddyFeedback.nextTransition(after: Date()) else { return }
        let transition = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.now = Date()
            self.scheduleFeedbackTransition()
        }
        feedbackTransition = transition
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: transition)
    }
    var reaction: Bool {
        guard let date = document.preferences.reactionAt else { return false }
        return now >= date && now.timeIntervalSince(date) < 4
    }
    var windows: [QuotaWindow] {
        document.records.first { $0.providerId == document.preferences.providerId }?.windows ?? []
    }
}

enum StandaloneSurface: Equatable { case desktop, menuBar }

/// Only this small header region drags the window; the rail remains interactive.
private struct WindowDragHandle: NSViewRepresentable {
    let locked: Bool
    final class Handle: NSView {
        var locked = false
        private var dragStart: (mouse: NSPoint, origin: NSPoint)?
        // The desktop panel intentionally stays nonactivating. Accept the
        // initial click so a drag can start while another application is key.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // Keep physical and remote mouse streams on the same AppKit tracking
        // path instead of handing this region to Window Server dragging.
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard !locked, let window, window.isMovable else { dragStart = nil; return }
            dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
            trace("down", event: event)
        }
        override func mouseDragged(with event: NSEvent) {
            guard !locked, let window, window.isMovable, let dragStart else { self.dragStart = nil; return }
            let mouse = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x,
                                          y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
            trace("drag", event: event)
        }
        override func mouseUp(with event: NSEvent) {
            trace("up", event: event)
            dragStart = nil
            if let window, window.frameAutosaveName != NSWindow.FrameAutosaveName("") {
                window.saveFrame(usingName: window.frameAutosaveName)
            }
        }
        private func trace(_ phase: String, event: NSEvent) {
            guard ProcessInfo.processInfo.environment["YULIANG_DRAG_TRACE"] == "1", let window else { return }
            let line = "\(phase) mouse=\(event.locationInWindow) frame=\(window.frame) locked=\(locked)\n"
            let url = URL(fileURLWithPath: "/private/tmp/yuliang-drag-trace.log")
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else { try? data.write(to: url) }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: locked ? .arrow : .openHand) }
    }
    func makeNSView(context: Context) -> Handle {
        let handle = Handle()
        handle.identifier = NSUserInterfaceItemIdentifier("yuliang.desktop.dragHandle")
        return handle
    }
    func updateNSView(_ nsView: Handle, context: Context) {
        nsView.locked = locked
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// A settings surface has its own text metrics and lifetime. In particular,
/// neither the 104-point widget nor SwiftUI Menu labels size its contents.
@MainActor
enum StandaloneMenuTracking {
    static let didEnd = Notification.Name("YuliangStandaloneMenuTrackingDidEnd")
    private static var activeSurfaces = Set<ObjectIdentifier>()
    static var isActive: Bool { !activeSurfaces.isEmpty }
    static func began(_ surface: AnyObject) { activeSurfaces.insert(ObjectIdentifier(surface)) }
    static func ended(_ surface: AnyObject) {
        guard activeSurfaces.remove(ObjectIdentifier(surface)) != nil, activeSurfaces.isEmpty else { return }
        NotificationCenter.default.post(name: didEnd, object: nil)
    }
}

enum StandaloneSettingsKind { case settings, interactions }

@MainActor
final class StandaloneSettingsPanelController: NSViewController {
    enum Page { case home, sources, styles, display, appearance, windows, characters, interactions }
    private final class ActionTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: NSButton) { action() }
    }
    private final class Surface: NSView {
        override var isFlipped: Bool { true }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            }
        }
    }
    let model: StandaloneModel?
    let surface: StandaloneSurface
    let kind: StandaloneSettingsKind
    var onClose: (() -> Void)?
    private(set) var page: Page
    private var targets: [ActionTarget] = []
    private var states: [(NSButton, () -> Bool)] = []
    private var enabledStates: [(NSButton, () -> Bool)] = []
    private var subscriptions = Set<AnyCancellable>()
    private var refreshScheduled = false
    private var structureSignature = ""
    private let interactionAction: (BuddyAction) -> Void
    private let interactionEnabled: () -> Bool
    private var documentView: NSView?
    private var nextY: CGFloat = 0

    init(model: StandaloneModel, surface: StandaloneSurface, kind: StandaloneSettingsKind) {
        self.model = model; self.surface = surface; self.kind = kind
        page = kind == .settings ? .home : .interactions
        interactionAction = { model.play($0) }
        interactionEnabled = { !model.isEatingUsage }
        super.init(nibName: nil, bundle: nil)
        model.objectWillChange.sink { [weak self] _ in self?.scheduleStateRefresh() }.store(in: &subscriptions)
        model.collector.objectWillChange.sink { [weak self] _ in self?.scheduleStateRefresh() }.store(in: &subscriptions)
        model.claudeCollector.objectWillChange.sink { [weak self] _ in self?.scheduleStateRefresh() }.store(in: &subscriptions)
    }
    init(action: @escaping (BuddyAction) -> Void, enabled: Bool) {
        model = nil; surface = .desktop; kind = .interactions; page = .interactions
        interactionAction = action; interactionEnabled = { enabled }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Settings are created from the current model") }

    override func loadView() {
        let root = Surface(frame: NSRect(x: 0, y: 0, width: 260, height: 380))
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 0.5
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        }
        root.identifier = NSUserInterfaceItemIdentifier(kind == .settings ? "yuliang.settings.surface" : "yuliang.interactions.surface")
        view = root
        preferredContentSize = NSSize(width: 260, height: 380)
        rebuildPage()
    }
    private func scheduleStateRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshState()
        }
    }
    private func currentStructureSignature() -> String {
        guard let model else { return "interactions" }
        if page == .windows { return model.windows.map { $0.id + "/" + $0.label }.joined(separator: "|") }
        if page == .characters { return model.availableCharacters.map(\.rawValue).joined(separator: "|") }
        return "\(page)"
    }
    private func refreshState() {
        guard isViewLoaded else { return }
        if structureSignature != currentStructureSignature() { rebuildPage(); return }
        for (button, selected) in states { button.state = selected() ? .on : .off }
        for (button, enabled) in enabledStates { button.isEnabled = enabled() }
        if let model { view.window?.appearance = model.appearance.nativeAppearance }
        view.needsDisplay = true
    }
    private func navigate(_ page: Page) { self.page = page; rebuildPage() }
    private var pageTitle: String {
        switch page {
        case .home: return "设置"
        case .sources: return "额度来源"
        case .styles: return "小组件样式"
        case .display: return "显示内容"
        case .appearance: return "外观"
        case .windows: return "额度窗口"
        case .characters: return "选择小伙伴"
        case .interactions: return "互动"
        }
    }
    private func rebuildPage() {
        guard isViewLoaded else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        targets.removeAll(); states.removeAll(); enabledStates.removeAll()
        structureSignature = currentStructureSignature()
        let hasBack = page != .home && kind == .settings
        if hasBack {
            makeButton("返回", id: "yuliang.settings.back", frame: NSRect(x: 10, y: 10, width: 42, height: 28), in: view) { [weak self] in self?.navigate(.home) }
        }
        let title = NSTextField(labelWithString: pageTitle)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: hasBack ? 54 : 12, y: 15, width: hasBack ? 152 : 194, height: 22)
        title.identifier = NSUserInterfaceItemIdentifier("yuliang.settings.pageTitle")
        view.addSubview(title)
        makeButton("关闭", id: "yuliang.settings.close", frame: NSRect(x: 208, y: 10, width: 42, height: 28), in: view) { [weak self] in self?.onClose?() }
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 48, width: 244, height: 324))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let body = Surface(frame: NSRect(x: 0, y: 0, width: 244, height: 324))
        documentView = body
        scroll.documentView = body
        view.addSubview(scroll)
        nextY = 0
        if let model {
            switch page {
            case .home:
                pair(("用量与额度详情", "details", { model.onConnect?() }),
                     ("立即刷新", "refresh", { model.refreshSelected() }))
                navigation("额度来源", page: .sources, id: "sources")
                navigation("小组件样式", page: .styles, id: "styles")
                navigation("显示内容", page: .display, id: "display")
                navigation("外观", page: .appearance, id: "appearance")
                navigation("额度窗口", page: .windows, id: "windows")
                navigation("选择小伙伴", page: .characters, id: "characters")
                navigation("互动", page: .interactions, id: "interactions")
                check("锁定位置", id: "positionLocked", selected: { model.positionLocked }) { model.positionLocked.toggle() }
                check("悬浮置顶", id: "pinned", selected: { model.pinned }) { model.pinned.toggle() }
                pair(("显示／收起卡片", "desktopVisible", { model.desktopVisible.toggle() }),
                     ("移回当前屏幕", "reposition", { model.onShowDesktop?() }))
                row("退出余量", id: "quit") { NSApplication.shared.terminate(nil) }
            case .sources:
                for provider in [QuotaProvider.codex, .claude] {
                    check(provider.name, id: "source." + provider.rawValue,
                          selected: { model.document.preferences.providerId == provider }, radio: true) { model.selectProvider(provider) }
                }
                row("连接 Claude 官网", id: "source.connectClaude") {
                    model.selectProvider(.claude)
                    model.onConnectClaude?()
                }
                row("查看当前额度详情", id: "source.details") { model.onConnect?() }
            case .styles:
                for style in StandaloneDisplayStyle.allCases {
                    check(style.label, id: "style." + style.rawValue, selected: { model.displayStyle == style }, radio: true) { model.displayStyle = style }
                }
            case .display:
                check("日 Token 用量", id: "display.dailyTokens", selected: { model.showDailyTokens }) { model.showDailyTokens.toggle() }
                check("累计 Token 用量", id: "display.lifetimeTokens", selected: { model.showLifetimeTokens }) { model.showLifetimeTokens.toggle() }
                check("紧凑模式", id: "display.compact", selected: { model.compact }) { model.compact.toggle() }
                check("自主陪伴", id: "display.companion", selected: { model.companionEnabled }) { model.companionEnabled.toggle() }
            case .appearance:
                radioGroup {
                    for appearance in StandaloneAppearance.allCases {
                        check(appearance.label, id: "appearance." + appearance.rawValue, selected: { model.appearance == appearance }, radio: true) { model.appearance = appearance }
                    }
                }
                radioGroup {
                    for style in StandaloneWidgetColorStyle.allCases {
                        check(style.label, id: "widgetColor." + style.rawValue,
                              selected: { model.widgetColorStyle == style }, radio: true) { model.widgetColorStyle = style }
                    }
                }
            case .windows:
                if model.windows.isEmpty { row("等待首次读取", id: "window.empty", enabled: { false }) {} }
                for window in model.windows {
                    check(window.label, id: "window." + window.id, selected: {
                        QuotaPresentation(document: model.document, now: model.now).window?.id == window.id
                    }, radio: true) {
                        model.buddyActivity = nil
                        model.preference { $0.windowId = window.id }
                    }
                }
            case .characters:
                for character in model.availableCharacters {
                    check(character.name, id: "character." + character.rawValue,
                          selected: { model.document.preferences.character == character }, radio: true) { model.selectCharacter(character) }
                }
            case .interactions: appendInteractions()
            }
        } else { appendInteractions() }
        body.frame.size.height = max(324, nextY)
        refreshState()
    }
    private func appendInteractions() {
        for action in BuddyAction.interactiveActions {
            row(action.label, id: "interaction." + action.rawValue, enabled: interactionEnabled) { [interactionAction] in interactionAction(action) }
        }
        row("随机互动", id: "interaction.random", enabled: interactionEnabled) { [interactionAction] in
            interactionAction(BuddyAction.playfulActions.randomElement() ?? .pat)
        }
    }
    @discardableResult private func makeButton(_ title: String, id: String, frame: NSRect, in parent: NSView,
                                               type: NSButton.ButtonType = .momentaryPushIn,
                                               action: @escaping () -> Void) -> NSButton {
        let target = ActionTarget { [weak self] in action(); self?.refreshState() }
        targets.append(target)
        let button = NSButton(title: title, target: target, action: #selector(ActionTarget.invoke(_:)))
        button.frame = frame
        button.font = .systemFont(ofSize: 13)
        button.setButtonType(type)
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = type == .switch || type == .radio ? .imageLeft : .noImage
        button.contentTintColor = .labelColor
        button.cell?.lineBreakMode = .byClipping
        button.identifier = NSUserInterfaceItemIdentifier(id.hasPrefix("yuliang.") ? id : "yuliang.settings." + id)
        button.setAccessibilityLabel(title)
        parent.addSubview(button)
        return button
    }
    private func row(_ title: String, id: String, enabled: (() -> Bool)? = nil, action: @escaping () -> Void) {
        guard let documentView else { return }
        let button = makeButton(title, id: id, frame: NSRect(x: 6, y: nextY, width: 230, height: 30), in: documentView, action: action)
        if let enabled { enabledStates.append((button, enabled)) }
        nextY += 30
    }
    private func check(_ title: String, id: String, selected: @escaping () -> Bool, radio: Bool = false, action: @escaping () -> Void) {
        guard let documentView else { return }
        let button = makeButton(title, id: id, frame: NSRect(x: 6, y: nextY, width: 230, height: 30), in: documentView,
                                type: radio ? .radio : .switch, action: action)
        states.append((button, selected)); nextY += 30
    }
    private func radioGroup(_ build: () -> Void) {
        guard let parent = documentView else { return }
        let startY = nextY
        let group = Surface(frame: NSRect(x: 0, y: startY, width: 244, height: 1))
        parent.addSubview(group)
        documentView = group; nextY = 0
        build()
        group.frame.size.height = nextY
        documentView = parent; nextY += startY + 8
    }
    private func navigation(_ title: String, page: Page, id: String) {
        row(title + "  ›", id: "nav." + id) { [weak self] in self?.navigate(page) }
    }
    private func pair(_ left: (String, String, () -> Void), _ right: (String, String, () -> Void)) {
        guard let documentView else { return }
        let first = makeButton(left.0, id: left.1, frame: NSRect(x: 6, y: nextY, width: 116, height: 30), in: documentView, action: left.2)
        let second = makeButton(right.0, id: right.1, frame: NSRect(x: 126, y: nextY, width: 112, height: 30), in: documentView, action: right.2)
        first.font = .systemFont(ofSize: 11); second.font = .systemFont(ofSize: 11)
        if left.1 == "refresh", let model { enabledStates.append((first, { !model.selectedBusy })) }
        if right.1 == "refresh", let model { enabledStates.append((second, { !model.selectedBusy })) }
        nextY += 30
    }
}

@MainActor
enum StandaloneSettingsPresenter {
    private final class Panel: NSPanel {
        var onDismiss: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onDismiss?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") { onDismiss?() }
            else { super.keyDown(with: event) }
        }
    }
    @MainActor private final class Session {
        let panel: Panel
        let controller: StandaloneSettingsPanelController
        weak var anchorWindow: NSWindow?
        var observers: [NSObjectProtocol] = []
        init(controller: StandaloneSettingsPanelController, anchor: NSView, appearance: NSAppearance?) {
            self.controller = controller
            anchorWindow = anchor.window
            panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 380),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = controller.kind == .settings ? "余量 · 设置" : "余量 · 互动"
            panel.identifier = NSUserInterfaceItemIdentifier("yuliang.settings.panel")
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.appearance = appearance
            panel.contentViewController = controller
            panel.setContentSize(NSSize(width: 260, height: 380))
            panel.onDismiss = { StandaloneSettingsPresenter.close() }
            controller.onClose = { StandaloneSettingsPresenter.close() }
            position()
            if let anchorWindow {
                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: anchorWindow, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.position() }
                    })
                }
            }
        }
        func position() {
            let anchor = anchorWindow?.frame ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
            guard let visible = screen?.visibleFrame else { return }
            let x = anchor.maxX + 8 + 260 <= visible.maxX ? anchor.maxX + 8 : anchor.minX - 268
            let origin = NSPoint(x: min(max(visible.minX, x), visible.maxX - 260),
                                 y: min(max(visible.minY, anchor.maxY - 380), visible.maxY - 380))
            panel.setFrameOrigin(origin)
        }
        func finish() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            controller.onClose = nil
            panel.onDismiss = nil
            panel.orderOut(nil)
            panel.close()
            panel.contentViewController = nil
            StandaloneMenuTracking.ended(panel)
        }
    }
    private static var session: Session?
    static func show(model: StandaloneModel, surface: StandaloneSurface, kind: StandaloneSettingsKind, anchor: NSView) {
        close()
        present(StandaloneSettingsPanelController(model: model, surface: surface, kind: kind), anchor: anchor, appearance: model.appearance.nativeAppearance)
    }
    static func showInteractions(action: @escaping (BuddyAction) -> Void, enabled: Bool, anchor: NSView, appearance: NSAppearance?) {
        close()
        present(StandaloneSettingsPanelController(action: action, enabled: enabled), anchor: anchor, appearance: appearance)
    }
    private static func present(_ controller: StandaloneSettingsPanelController, anchor: NSView, appearance: NSAppearance?) {
        let current = Session(controller: controller, anchor: anchor, appearance: appearance)
        session = current
        StandaloneMenuTracking.began(current.panel)
        current.panel.makeKeyAndOrderFront(nil)
        current.panel.orderFrontRegardless()
    }
    static func close() {
        let previous = session
        session = nil
        previous?.finish()
    }
    #if QUOTA_SHELL_TESTING
    static var shellTestPanel: NSPanel? { session?.panel }
    static var shellTestController: StandaloneSettingsPanelController? { session?.controller }
    #endif
}

/// Only contextual clicks enter this view; ordinary taps reach the character.
struct StandaloneBuddyContextMenu: NSViewRepresentable {
    let action: (BuddyAction) -> Void
    var enabled = true
    @Environment(\.colorScheme) private var colorScheme
    final class ContextView: NSView {
        var action: ((BuddyAction) -> Void)?
        var enabled = true
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || event.type == .rightMouseUp
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
            return super.hitTest(point)
        }
        override func rightMouseDown(with event: NSEvent) { showPanel() }
        override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { showPanel() } }
        private func showPanel() {
            guard let action else { return }
            StandaloneSettingsPresenter.showInteractions(action: action, enabled: enabled, anchor: self, appearance: appearance)
        }
    }
    func makeNSView(context: Context) -> ContextView {
        let view = ContextView()
        view.identifier = NSUserInterfaceItemIdentifier("yuliang.buddy.contextMenu")
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: ContextView, context: Context) {
        view.action = action; view.enabled = enabled
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

/// A transparent context surface leaves normal taps, rail gestures and header
/// dragging with their existing receivers. Character context clicks keep their
/// own interaction panel even when the character moves along the rail or ring.
struct StandaloneWidgetContextMenu: NSViewRepresentable {
    @ObservedObject var model: StandaloneModel
    let surface: StandaloneSurface

    final class ContextView: NSView {
        weak var model: StandaloneModel?
        var surface = StandaloneSurface.desktop
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        func acceptsContextClick(_ event: NSEvent, at windowPoint: NSPoint) -> Bool {
            guard event.type == .rightMouseDown || event.type == .rightMouseUp
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                  bounds.contains(convert(windowPoint, from: nil)) else { return false }
            guard let root = window?.contentView else { return false }
            return !containsCharacterContext(at: windowPoint, in: root)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let localPoint = convert(point, from: superview)
            guard acceptsContextClick(event, at: convert(localPoint, to: nil)) else { return nil }
            return super.hitTest(point)
        }

        private func containsCharacterContext(at windowPoint: NSPoint, in view: NSView) -> Bool {
            guard !view.isHidden, view.alphaValue > 0 else { return false }
            if view.identifier?.rawValue == "yuliang.buddy.contextMenu",
               view.convert(view.bounds, to: nil).contains(windowPoint) { return true }
            return view.subviews.contains { containsCharacterContext(at: windowPoint, in: $0) }
        }

        override func rightMouseDown(with event: NSEvent) { showPanel() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { showPanel() }
        }
        override func accessibilityPerformShowMenu() -> Bool { showPanel() }

        @discardableResult
        private func showPanel() -> Bool {
            guard let model, window != nil else { return false }
            StandaloneSettingsPresenter.show(model: model, surface: surface, kind: .settings, anchor: self)
            return true
        }
    }

    func makeNSView(context: Context) -> ContextView {
        let view = ContextView()
        view.identifier = NSUserInterfaceItemIdentifier("yuliang.widget.contextMenu")
        view.setAccessibilityIdentifier("yuliang.widget.contextMenu")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("小组件设置")
        view.setAccessibilityHelp("右键或按住 Control 点击，打开设置")
        return view
    }

    func updateNSView(_ view: ContextView, context: Context) {
        view.model = model
        view.surface = surface
    }
}

private struct StandaloneNativeMenuButton: NSViewRepresentable {
    @ObservedObject var model: StandaloneModel
    let surface: StandaloneSurface
    var kind = StandaloneSettingsKind.settings
    final class Button: NSButton { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }
    @MainActor final class Coordinator: NSObject {
        var model: StandaloneModel
        var surface: StandaloneSurface
        var kind: StandaloneSettingsKind
        private var appliedStyle: String?
        init(model: StandaloneModel, surface: StandaloneSurface, kind: StandaloneSettingsKind) {
            self.model = model; self.surface = surface; self.kind = kind
        }
        @objc func open(_ sender: NSButton) { StandaloneSettingsPresenter.show(model: model, surface: surface, kind: kind, anchor: sender) }
        func updateButton(_ button: NSButton) {
            let settings = kind == .settings
            let signature = "\(settings)/\(model.appearance.rawValue)/\(model.document.preferences.character.rawValue)/\(model.isEatingUsage)"
            guard signature != appliedStyle else { return }
            button.title = settings ? "设置" : ""
            button.image = settings ? nil : NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.imagePosition = settings ? .noImage : .imageOnly
            button.contentTintColor = settings ? .secondaryLabelColor : NSColor(QuotaPalette.accent(for: model.document.preferences.character))
            button.appearance = model.appearance.nativeAppearance
            button.identifier = NSUserInterfaceItemIdentifier(settings ? "yuliang.settings.button" : "yuliang.interactions.button")
            button.setAccessibilityLabel(settings ? "设置" : "互动动作")
            button.isEnabled = settings || !model.isEatingUsage
            appliedStyle = signature
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model, surface: surface, kind: kind) }
    func makeNSView(context: Context) -> Button {
        let button = Button(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false; button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 10, weight: .medium)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        context.coordinator.model = model; context.coordinator.surface = surface; context.coordinator.kind = kind
        context.coordinator.updateButton(button)
    }
}

struct StandalonePanelView: View {
    @ObservedObject var model: StandaloneModel
    @ObservedObject var collector: CodexQuotaCollector
    @ObservedObject var claudeCollector: QuotaWebCollector
    let surface: StandaloneSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: StandaloneModel, surface: StandaloneSurface = .desktop) {
        self.model = model; self.collector = model.collector; self.claudeCollector = model.claudeCollector; self.surface = surface
    }
    var accent: Color { QuotaPalette.accent(for: model.document.preferences.character) }
    var presentation: QuotaPresentation { QuotaPresentation(document: model.document, now: model.now) }
    private var isDuo: Bool { surface == .desktop && model.displayStyle == .duo }
    var body: some View {
        Group {
            if isDuo { duoBody }
            else { cardBody }
        }
        .saturation(surface == .desktop && model.widgetColorStyle.isMonochrome(desktopIsForeground: model.desktopIsForeground) ? 0 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.desktopIsForeground)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.widgetColorStyle)
        .frame(width: isDuo ? 160 : StandaloneLayout.cardWidth(compact: model.compact), height: StandaloneLayout.height)
        .background {
            if surface == .desktop {
                StandaloneWidgetMaterial(emphasized: !model.widgetColorStyle.isMonochrome(desktopIsForeground: model.desktopIsForeground))
                    .clipShape(RoundedRectangle(cornerRadius: StandaloneLayout.cornerRadius, style: .continuous))
            } else { QuotaPalette.surface }
        }
        .buttonStyle(.plain)
        .overlay {
            if surface == .desktop {
                StandaloneWidgetContextMenu(model: model, surface: surface)
            }
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: presentation.provider == .claude ? "sparkle" : "circle.hexagongrid.fill").font(.system(size: 10))
                    Text(presentation.provider.name).font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    if surface == .desktop {
                        WindowDragHandle(locked: model.positionLocked)
                            .help(model.positionLocked ? "位置已锁定" : "拖动小组件")
                    }
                }
                if surface == .menuBar {
                    Button { model.onShowDesktop?() } label: { Image(systemName: "macwindow.badge.plus") }
                        .help("显示桌面卡片").accessibilityLabel("显示桌面卡片")
                    settingsMenu
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 18)
            QuotaCard(document: model.document, now: model.now, compact: true,
                      reaction: model.reaction, onPat: model.pat, animateChanges: model.animateQuota,
                      activity: model.buddyActivity, onAction: model.play, minimal: true, slim: true)
                .frame(height: 66)
            Group {
                if presentation.provider == .claude {
                    claudeWindowStrip
                } else if model.showDailyTokens || model.showLifetimeTokens {
                    HStack(spacing: 12) {
                        if model.showDailyTokens {
                            tokenValue("日用量 · \(TokenUsageFormat.day(collector.tokenUsage?.serverDay))",
                                       value: collector.tokenUsage?.serverDayTokens, daily: true)
                        }
                        if model.showLifetimeTokens {
                            tokenValue("累计用量", value: collector.tokenUsage?.lifetimeTokens, daily: false)
                        }
                    }
                } else { Color.clear.accessibilityHidden(true) }
            }.frame(height: 28)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                feedbackFooter
                Spacer(minLength: 2)
                Button(action: model.feed) { CookieBiscuit(bitten: false).frame(width: 14, height: 14).frame(width: 22, height: 22) }
                    .disabled(model.isEatingUsage).help("喂一块饼干").accessibilityLabel("喂一块饼干")
                StandaloneNativeMenuButton(model: model, surface: surface, kind: .interactions)
                    .frame(width: 22, height: 22)
                Button { model.onChooseCharacter?(surface) } label: {
                    Image(systemName: "person.crop.circle").frame(width: 22, height: 22)
                }.help("选择小伙伴 · \(model.document.preferences.character.name)").accessibilityLabel("切换小伙伴")
            }.font(.system(size: 12)).foregroundStyle(accent).frame(height: 22)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var feedbackFooter: some View {
        let message = model.feedbackMessage
        return Button { model.onConnect?() } label: {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: message.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(message.kind == .error ? Color.secondary : accent)
                    .accessibilityHidden(true)
                Text(message.text)
                    .font(.system(size: 11, weight: message.kind == .interaction ? .medium : .regular))
                    .foregroundStyle(message.kind == .interaction ? Color.primary : Color.secondary)
                    .lineLimit(isDuo ? 2 : 1)
                    .multilineTextAlignment(isDuo ? .center : .leading)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, minHeight: isDuo ? 26 : 22, maxHeight: isDuo ? 26 : 22,
                   alignment: isDuo ? .center : .leading)
            .contentShape(Rectangle())
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: message)
        .help(feedbackHelp)
        .accessibilityLabel(message.text)
        .accessibilityIdentifier("yuliang.widget.feedback")
    }

    private var feedbackHelp: String {
        var lines = [model.feedbackMessage.text]
        if let detail = model.error ?? model.selectedQuotaError { lines.append(detail) }
        lines.append(presentation.observedAt.map { "额度更新 " + $0.formatted(date: .abbreviated, time: .standard) } ?? "额度尚未读取")
        lines.append("点按查看用量与额度详情")
        return lines.joined(separator: "\n")
    }

    private var duoBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                HStack(spacing: 4) {
                    Text(presentation.provider.name).font(.system(size: 11, weight: .semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                    .overlay {
                        WindowDragHandle(locked: model.positionLocked)
                            .help(model.positionLocked ? "位置已锁定" : "拖动小组件")
                    }
            }.foregroundStyle(.secondary).frame(height: 16)
            QuotaDuoGauge(document: model.document, now: model.now, reaction: model.reaction,
                          onPat: model.pat, animateChanges: model.animateQuota,
                          activity: model.buddyActivity, onAction: model.play, size: 86)
                .frame(height: 86)
            HStack(spacing: 8) {
                if presentation.provider == .claude {
                    Text(presentation.window?.label ?? "待连接")
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                } else if model.showDailyTokens {
                    duoToken("日", value: collector.tokenUsage?.serverDayTokens, daily: true)
                }
                if presentation.provider == .codex && model.showLifetimeTokens {
                    duoToken("累计", value: collector.tokenUsage?.lifetimeTokens, daily: false)
                }
            }.frame(height: 14)
            feedbackFooter
        }.padding(.horizontal, 10).padding(.vertical, 9)
    }

    private var claudeWindowStrip: some View {
        HStack(spacing: 12) {
            if model.windows.isEmpty {
                Button("连接 Claude 官网") { model.onConnectClaude?() }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .accessibilityIdentifier("yuliang.claude.connect")
            } else {
                ForEach(Array(model.windows.prefix(2))) { window in
                    Button { model.preference { $0.windowId = window.id } } label: {
                        HStack(spacing: 4) {
                            Circle().fill(presentation.window?.id == window.id ? accent : Color.secondary.opacity(0.3))
                                .frame(width: 4, height: 4)
                            Text(window.label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            Text(window.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.help(window.resetAt.map { "重置 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "未提供重置时间")
                        .accessibilityLabel("\(window.label)，\(window.remainingPercent.map { "剩余百分之\(Int($0.rounded()))" } ?? "额度未知")")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duoToken(_ label: String, value: Int64?, daily: Bool) -> some View {
        Button { model.onConnect?() } label: {
            HStack(spacing: 3) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if collector.tokenUsage != nil && collector.tokenUsageState != .available {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                }
                Text(TokenUsageFormat.compact(value)).monospacedDigit().fontWeight(.medium)
            }.font(.system(size: 9)).frame(height: 12)
        }
        .help("\(daily ? "服务端日统计 · " + TokenUsageFormat.day(collector.tokenUsage?.serverDay) : "账号累计统计") · \(TokenUsageFormat.exact(value))\n\(collector.tokenUsageStatus)")
        .accessibilityLabel("\(daily ? "日 Token 用量" : "累计 Token 用量")，\(TokenUsageFormat.exact(value))，\(collector.tokenUsageStatus)")
    }

    private func tokenValue(_ label: String, value: Int64?, daily: Bool) -> some View {
        let outdated = collector.tokenUsage != nil && collector.tokenUsageState != .available
        let timestamp = collector.tokenUsageLastSuccessAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "尚未读取"
        return Button { model.onConnect?() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(label)
                    if outdated { Image(systemName: "clock.badge.exclamationmark") }
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(TokenUsageFormat.compact(value)).font(.system(size: model.compact ? 14 : 17, weight: .semibold, design: .rounded))
                    Text("Token").font(.system(size: 9)).foregroundStyle(.secondary)
                }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .help("\(daily ? "服务端日统计，时区未注明" : "账号累计统计") · \(TokenUsageFormat.exact(value))\n\(collector.tokenUsageStatus) · 更新 \(timestamp)")
        .accessibilityLabel("\(label)，\(TokenUsageFormat.exact(value))，\(outdated ? "保留上次数据" : collector.tokenUsageStatus)")
    }

    private var settingsMenu: some View {
        StandaloneNativeMenuButton(model: model, surface: surface)
            .frame(width: 36, height: 18)
    }
}

struct StandaloneCharacterPicker: View {
    @ObservedObject var model: StandaloneModel
    var onSelect: () -> Void
    private var rowCount: Int { (model.availableCharacters.count + 2) / 3 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择小伙伴").font(.system(size: 14, weight: .semibold))
            VStack(spacing: 7) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            if index < model.availableCharacters.count {
                                characterButton(model.availableCharacters[index])
                            } else {
                                Color.clear.frame(width: 82, height: 90).accessibilityHidden(true)
                            }
                        }
                    }
                }
            }.frame(width: 260)
        }
        .padding(16).frame(width: 292)
        .fixedSize()
        .background(QuotaPalette.surface)
    }

    private func characterButton(_ character: QuotaCharacter) -> some View {
        let selected = model.document.preferences.character == character
        let accent = QuotaPalette.accent(for: character)
        return Button {
            model.selectCharacter(character)
            onSelect()
        } label: {
            VStack(spacing: 3) {
                BuddySprite(character: character, frame: selected ? 4 : 0, size: 60)
                    .allowsHitTesting(false)
                Text(character.name).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(width: 82, height: 90)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.10) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        .padding(5).foregroundStyle(accent)
                }
            }
            .foregroundStyle(QuotaPalette.ink)
        }
        .buttonStyle(.plain).accessibilityLabel(character.name)
        .accessibilityValue(selected ? "已选择" : "未选择")
    }
}

struct StandaloneConnectionView: View {
    @ObservedObject var model: StandaloneModel
    @ObservedObject var collector: CodexQuotaCollector
    init(model: StandaloneModel) { self.model = model; self.collector = model.collector }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("用量与额度").font(.title2.bold())
                    Spacer()
                    if collector.isRunning { Button("暂停") { collector.pause() } }
                    else { Button("开始刷新") { collector.start() } }
                    Button("刷新") { collector.refreshNow() }.disabled(collector.isBusy)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("订阅额度").font(.system(size: 13, weight: .semibold))
                    if model.windows.isEmpty { Text("等待官方接口返回额度窗口").foregroundStyle(.secondary) }
                    ForEach(model.windows) { window in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(window.label).font(.system(size: 12, weight: .medium))
                                Text(window.resetAt.map { "重置 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "未提供重置时间")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(window.remainingPercent.map { "剩余 \(Int($0.rounded()))%" } ?? "未提供")
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                    }
                    Text(collector.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(collector.lastSuccessAt.map { "额度更新 \($0.formatted(date: .abbreviated, time: .standard))" } ?? "额度尚未读取")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Token 使用量").font(.system(size: 13, weight: .semibold))
                    usageRow("日用量 · \(collector.tokenUsage?.serverDay ?? "日期未知")", collector.tokenUsage?.serverDayTokens)
                    usageRow("累计用量", collector.tokenUsage?.lifetimeTokens)
                    Text(collector.tokenUsageStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(collector.tokenUsageLastSuccessAt.map { "用量更新 \($0.formatted(date: .abbreviated, time: .standard))" } ?? "用量尚未读取")
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    Text("日用量使用官方返回的最新统计日，服务端未注明时区。累计使用量独立读取，不通过额度百分比换算；缺失项显示未知，读取失败时保留上次数据。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("每 \(Int(collector.interval)) 秒自动查询，复用本机 Codex CLI 登录。请求慢或限流时顺延；仅查询，不发起对话任务。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if collector.needsLogin || collector.tokenUsageState == .loginRequired {
                    Text("请先在官方 Codex 中登录；CLI 尚未登录时，可在终端运行 codex login，完成后重试。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                Label("仅读取额度和用量摘要，不读取密码、令牌或对话正文。", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(22)
        }.frame(width: 430, height: 520).background(QuotaPalette.surface)
            .preferredColorScheme(model.appearance.colorScheme)
    }
    private func usageRow(_ label: String, _ value: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12))
            Spacer(minLength: 8)
            Text(TokenUsageFormat.exact(value)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }
}

/// Provider selection changes presentation only; each collector retains its own
/// account session and history. Claude never borrows Codex token statistics.
struct StandaloneConnectionRootView: View {
    @ObservedObject var model: StandaloneModel
    @ObservedObject var claude: QuotaWebCollector
    init(model: StandaloneModel) { self.model = model; self.claude = model.claudeCollector }
    var body: some View {
        VStack(spacing: 0) {
            Picker("额度来源", selection: Binding(get: { model.document.preferences.providerId }, set: model.selectProvider)) {
                Text("Codex").tag(QuotaProvider.codex)
                Text("Claude").tag(QuotaProvider.claude)
            }.pickerStyle(.segmented).padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 6)
            if model.document.preferences.providerId == .codex {
                StandaloneConnectionView(model: model)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Claude 订阅额度").font(.system(size: 18, weight: .semibold))
                            Spacer()
                            Button("连接官网") { model.onConnectClaude?() }
                                .buttonStyle(.borderedProminent)
                        }
                        Text(claude.status).font(.callout).foregroundStyle(.secondary)
                        if let error = claude.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                        if model.windows.isEmpty {
                            Text("在连接窗口登录官网后，开启每 60 秒自动读取。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.windows) { window in
                            Button { model.preference { $0.windowId = window.id } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(window.label).font(.system(size: 12, weight: .semibold))
                                        Text(window.resetAt.map { "重置 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "官网未提供重置时间")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(window.remainingPercent.map { "剩余 \(Int($0.rounded()))%" } ?? "未知")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                                }.padding(12).background(QuotaPalette.track, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            if claude.isRunning { Button("暂停") { claude.pause() } }
                            else { Button("开始刷新") { claude.start() }.disabled(!claude.hasUsagePage) }
                            Button("立即刷新") { claude.refreshNow() }.disabled(!claude.hasUsagePage || claude.isBusy)
                        }
                        Text(claude.lastSuccessAt.map { "上次成功读取 " + $0.formatted(date: .abbreviated, time: .standard) } ?? "尚未读取")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Claude 官网订阅额度独立保存，不与 Codex 合并。官网未显示 Token 使用量时不推算；外部浏览器的登录不会自动同步到应用的连接窗口。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(22)
                }.frame(width: 430, height: 520)
            }
        }.frame(width: 430, height: 566).background(QuotaPalette.surface)
            .preferredColorScheme(model.appearance.colorScheme)
    }
}
