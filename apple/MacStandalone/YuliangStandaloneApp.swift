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
    @Published var buddyActivity: BuddyActivity?
    private var clock: AnyCancellable?
    private var lastPlay: BuddyAction = .idle
    let collector: CodexQuotaCollector
    let store: StandaloneQuotaStore
    var onConnect: (() -> Void)?
    var onChooseCharacter: ((StandaloneSurface) -> Void)?
    var onResize: ((Bool) -> Void)?
    var onPin: ((Bool) -> Void)?
    var onPositionLock: ((Bool) -> Void)?
    var onDesktopVisibility: ((Bool) -> Void)?
    var onShowDesktop: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    var onAppearance: ((StandaloneAppearance) -> Void)?

    init(store: StandaloneQuotaStore = .shared) {
        self.store = store
        self.collector = CodexQuotaCollector()
        do { document = try store.read() }
        catch { self.error = error.localizedDescription }
        if document.preferences.providerId != .codex {
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
        collector.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let previous = QuotaPresentation(document: self.document)
            _ = try self.store.ingest(snapshot)
            let latest = try self.store.read()
            let next = QuotaPresentation(document: latest)
            self.animateQuota = previous.provider == next.provider
                && previous.window?.id == next.window?.id
                && previous.freshness == .fresh && next.freshness == .fresh
                && previous.remainingPercent != nil && next.remainingPercent != nil
                && previous.remainingPercent != next.remainingPercent
                && (next.observedAt ?? .distantPast) > (previous.observedAt ?? .distantFuture)
            self.document = latest
            self.now = Date()
            if let consumed = BuddyQuotaChange.consumption(from: previous, to: next) {
                self.buddyActivity = BuddyActivity(action: .eating, startedAt: self.now, source: .usage, consumedPercent: consumed)
            }
            self.error = nil
        }
        clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }
            self.now = date
            if let activity = self.buddyActivity, date.timeIntervalSince(activity.startedAt) >= activity.duration {
                self.buddyActivity = nil
            }
        }
    }
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
        buddyActivity = BuddyActivity(action: action, startedAt: Date(), source: .play)
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
    }
    func switchCharacter() {
        let index = availableCharacters.firstIndex(of: document.preferences.character) ?? -1
        selectCharacter(availableCharacters[(index + 1) % availableCharacters.count])
    }
    var isEatingUsage: Bool {
        guard let activity = buddyActivity else { return false }
        return activity.action == .eating && activity.source == .usage && Date().timeIntervalSince(activity.startedAt) < activity.duration
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

struct StandalonePanelView: View {
    @ObservedObject var model: StandaloneModel
    @ObservedObject var collector: CodexQuotaCollector
    let surface: StandaloneSurface
    init(model: StandaloneModel, surface: StandaloneSurface = .desktop) {
        self.model = model; self.collector = model.collector; self.surface = surface
    }
    var accent: Color { QuotaPalette.accent(for: model.document.preferences.character) }
    var presentation: QuotaPresentation { QuotaPresentation(document: model.document, now: model.now) }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 9))
                    Text("Codex").font(.system(size: 11, weight: .semibold))
                    if surface == .desktop {
                        Image(systemName: "line.3.horizontal").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    if surface == .desktop {
                        WindowDragHandle(locked: model.positionLocked)
                            .help(model.positionLocked ? "位置已锁定" : "拖动小组件")
                    }
                }
                if surface == .desktop {
                    Button { model.positionLocked.toggle() } label: {
                        Image(systemName: model.positionLocked ? "lock.fill" : "lock.open")
                    }
                    .help(model.positionLocked ? "解锁位置" : "锁定位置")
                    .accessibilityLabel(model.positionLocked ? "解锁位置" : "锁定位置")
                    Button { model.desktopVisible = false } label: { Image(systemName: "minus") }
                        .help("收起桌面卡片").accessibilityLabel("收起桌面卡片")
                } else {
                    Button { model.onShowDesktop?() } label: { Image(systemName: "macwindow.badge.plus") }
                        .help("显示桌面卡片").accessibilityLabel("显示桌面卡片")
                }
                settingsMenu
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            QuotaCard(document: model.document, now: model.now, compact: model.compact,
                      reaction: model.reaction, onPat: model.pat, animateChanges: model.animateQuota,
                      activity: model.buddyActivity, onAction: model.play, minimal: true)
            if model.showDailyTokens || model.showLifetimeTokens {
                HStack(spacing: 18) {
                    if model.showDailyTokens {
                        tokenValue("日用量 · \(TokenUsageFormat.day(collector.tokenUsage?.serverDay))",
                                   value: collector.tokenUsage?.serverDayTokens, daily: true)
                    }
                    if model.showLifetimeTokens {
                        tokenValue("累计用量", value: collector.tokenUsage?.lifetimeTokens, daily: false)
                    }
                }.padding(.top, 1)
            }
            HStack(spacing: 13) {
                Button { model.onConnect?() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 9))
                        if let date = presentation.observedAt {
                            Text("额度 \(date.formatted(date: .omitted, time: .shortened))").monospacedDigit()
                        } else { Text("等待读取额度") }
                    }.font(.system(size: 9)).foregroundStyle(Color.secondary)
                }.help("查看用量、额度及各自更新时间").accessibilityLabel("用量与额度详情")
                Spacer(minLength: 0)
                Button(action: model.feed) { CookieBiscuit(bitten: false).frame(width: 16, height: 16).frame(width: 24, height: 24) }
                    .disabled(model.isEatingUsage).help("喂一块饼干").accessibilityLabel("喂一块饼干")
                Menu {
                    ForEach(BuddyAction.interactiveActions, id: \.self) { action in
                        Button { model.play(action) } label: { Label(action.label, systemImage: action.symbol) }
                    }
                    Divider()
                    Button("随机互动") { model.pat() }
                } label: { Image(systemName: "sparkles").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.isEatingUsage)
                    .help("和小伙伴玩").accessibilityLabel("互动动作")
                Button { model.onChooseCharacter?(surface) } label: {
                    Image(systemName: "person.crop.circle").frame(width: 24, height: 24)
                }.help("选择小伙伴 · \(model.document.preferences.character.name)").accessibilityLabel("切换小伙伴")
            }.font(.system(size: 12)).foregroundStyle(accent)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(width: 320)
        .background(QuotaPalette.surface, in: RoundedRectangle(cornerRadius: surface == .desktop ? 22 : 0))
        .buttonStyle(.plain)
    }

    private func tokenValue(_ label: String, value: Int64?, daily: Bool) -> some View {
        let outdated = collector.tokenUsage != nil && collector.tokenUsageState != .available
        let timestamp = collector.tokenUsageLastSuccessAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "尚未读取"
        return Button { model.onConnect?() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Text(label)
                    if outdated { Image(systemName: "clock.badge.exclamationmark") }
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(TokenUsageFormat.compact(value)).font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Token").font(.system(size: 9)).foregroundStyle(.secondary)
                }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .help("\(daily ? "服务端日统计，时区未注明" : "账号累计统计") · \(TokenUsageFormat.exact(value))\n\(collector.tokenUsageStatus) · 更新 \(timestamp)")
        .accessibilityLabel("\(label)，\(TokenUsageFormat.exact(value))，\(outdated ? "保留上次数据" : collector.tokenUsageStatus)")
    }

    private var settingsMenu: some View {
        Menu {
            Button("用量与额度详情") { model.onConnect?() }
            Button("立即刷新") { collector.refreshNow() }.disabled(collector.isBusy)
            Menu("额度窗口") {
                if model.windows.isEmpty { Text("等待首次读取") }
                ForEach(model.windows) { window in
                    Button(window.label) {
                        model.buddyActivity = nil
                        model.preference { $0.windowId = window.id }
                    }
                }
            }
            Divider()
            Menu("显示内容") {
                Toggle("日 Token 用量", isOn: $model.showDailyTokens)
                Toggle("累计 Token 用量", isOn: $model.showLifetimeTokens)
                Toggle("紧凑模式", isOn: $model.compact)
            }
            Menu("外观") {
                ForEach(StandaloneAppearance.allCases, id: \.self) { appearance in
                    Button { model.appearance = appearance } label: {
                        if model.appearance == appearance { Label(appearance.label, systemImage: "checkmark") }
                        else { Text(appearance.label) }
                    }
                }
            }
            Toggle("锁定位置", isOn: $model.positionLocked)
            Toggle("悬浮置顶", isOn: $model.pinned)
            Button(model.desktopVisible ? "收起桌面卡片" : "显示桌面卡片") { model.desktopVisible.toggle() }
            Button("移回当前屏幕") { model.onShowDesktop?() }
            Divider()
            Button("退出余量") { NSApplication.shared.terminate(nil) }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("设置")
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
