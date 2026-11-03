import AppKit
import SwiftUI
import Combine
import QuotaCore

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
        let choices: [BuddyAction] = [.pat, .wave, .nap, .celebrate].filter { $0 != lastPlay }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 9))
                    Text("余量").font(.system(size: 11, weight: .semibold))
                    if surface == .desktop {
                        Image(systemName: "line.3.horizontal").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    if surface == .desktop {
                        WindowDragHandle(locked: model.positionLocked)
                            .help(model.positionLocked ? "位置已锁定，点击锁按钮即可解锁" : "自由拖动，放到你喜欢的位置")
                    }
                }
                if surface == .desktop {
                    Button { model.positionLocked.toggle() } label: {
                        Image(systemName: model.positionLocked ? "lock.fill" : "lock.open")
                    }
                    .help(model.positionLocked ? "位置已锁定，点击恢复自由拖动" : "可以自由拖动，点击锁定当前位置")
                    .accessibilityLabel(model.positionLocked ? "解锁位置" : "锁定位置")
                    Button { model.desktopVisible = false } label: { Image(systemName: "minus") }
                        .help("收起桌面卡片，菜单栏仍会自动刷新").accessibilityLabel("收起桌面卡片")
                } else {
                    Button { model.onShowDesktop?() } label: { Image(systemName: "macwindow.badge.plus") }
                        .help("显示桌面卡片").accessibilityLabel("显示桌面卡片")
                }
                Menu {
                    Button("Codex 额度详情") { model.onConnect?() }
                    Divider()
                    Button(model.desktopVisible ? "收起桌面卡片" : "显示桌面卡片") { model.desktopVisible.toggle() }
                    Button("移回当前屏幕") { model.onShowDesktop?() }
                    Toggle("锁定位置", isOn: $model.positionLocked)
                    Toggle("悬浮置顶", isOn: $model.pinned)
                    Toggle("紧凑模式", isOn: $model.compact)
                    Divider()
                    Button("喂一块饼干") { model.feed() }
                    Button("和小伙伴玩") { model.pat() }
                    Menu("选择小伙伴") {
                        ForEach(model.availableCharacters, id: \.self) { character in
                            Button { model.selectCharacter(character) } label: {
                                if model.document.preferences.character == character {
                                    Label(character.name, systemImage: "checkmark")
                                } else { Text(character.name) }
                            }
                        }
                    }
                    Divider()
                    Button("退出余量") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("设置")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            QuotaCard(document: model.document, now: model.now, compact: model.compact,
                      reaction: model.reaction, onPat: model.pat, animateChanges: model.animateQuota,
                      activity: model.buddyActivity, onAction: model.play)
            HStack(spacing: 4) {
                Circle().fill(accent.opacity(0.6)).frame(width: 3, height: 3)
                Text(model.buddyActivity?.caption ?? "点击小伙伴互动，额度减少时会自动吃饼干")
                    .font(.system(size: 9)).lineLimit(1).foregroundStyle(accent.opacity(0.85))
                Spacer(minLength: 0)
            }.frame(height: 13).accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 0) {
                Button { model.onConnect?() } label: { Image(systemName: "chart.pie").frame(maxWidth: .infinity, minHeight: 27) }
                    .help("查看 Codex 额度与连接状态").accessibilityLabel("额度详情")
                Menu {
                    if model.windows.isEmpty { Text("等待首次读取") }
                    ForEach(model.windows) { window in
                        Button(window.label) {
                            model.buddyActivity = nil
                            model.preference { $0.windowId = window.id }
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 27) }
                    .menuStyle(.borderlessButton).help("选择额度窗口").accessibilityLabel("选择额度窗口")
                Button { collector.refreshNow() } label: { Image(systemName: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 27) }
                    .disabled(collector.isBusy).help("立即读取 Codex 额度").accessibilityLabel("立即刷新")
                Button(action: model.feed) { CookieBiscuit(bitten: false).frame(width: 17, height: 17).frame(maxWidth: .infinity, minHeight: 27) }
                    .disabled(model.isEatingUsage).help("喂一块小饼干，仅互动，不改变真实额度").accessibilityLabel("喂一块饼干")
                Button { model.onChooseCharacter?(surface) } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark").frame(maxWidth: .infinity, minHeight: 27)
                }
                    .help("选择小伙伴 · 当前\(model.document.preferences.character.name)").accessibilityLabel("切换小伙伴")
            }.font(.system(size: 12)).foregroundStyle(accent)

        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 13)
        .frame(width: 320)
        .background(.white, in: RoundedRectangle(cornerRadius: surface == .desktop ? 22 : 0))
        .overlay {
            if surface == .desktop { RoundedRectangle(cornerRadius: 22).stroke(QuotaPalette.ink.opacity(0.07), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

struct StandaloneCharacterPicker: View {
    @ObservedObject var model: StandaloneModel
    var onSelect: () -> Void
    private var rowCount: Int { (model.availableCharacters.count + 2) / 3 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择小伙伴").font(.system(size: 14, weight: .semibold))
                Text("陪你开工，额度仍由 Codex 自动读取")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
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
            Text("右键小伙伴，可以挑选互动动作。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 292)
        .fixedSize()
        .background(.white)
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Codex 额度").font(.title2.bold())
                    Spacer()
                    if collector.isRunning { Button("暂停") { collector.pause() } }
                    else { Button("开始 \(Int(collector.interval)) 秒刷新") { collector.start() } }
                    Button("立即读取") { collector.refreshNow() }.disabled(collector.isBusy)
                }
                Text("复用本机 Codex CLI 的登录，读取账号共享额度。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            if model.windows.isEmpty {
                Text("等待官方接口返回额度窗口").foregroundStyle(.secondary)
            }
            ForEach(model.windows) { window in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(window.label).font(.system(size: 13, weight: .semibold))
                        if let resetAt = window.resetAt {
                            Text("重置 \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Text("未提供重置时间").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(window.remainingPercent.map { "剩余 \(Int($0.rounded()))%" } ?? "未提供")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
            }
            Divider()
            Label(collector.status, systemImage: collector.isRunning ? "arrow.triangle.2.circlepath" : "pause.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let date = collector.lastSuccessAt {
                Text("成功读取 \(date.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("目标每 \(Int(collector.interval)) 秒发起一次真实额度查询。请求慢或限流时顺延，失败保留旧额度；不会发起对话任务或消耗一次额度重置。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if collector.needsLogin {
                Text("请先在官方 Codex 中登录；如本机 CLI 尚未登录，可在终端运行 codex login，完成后返回此处重试。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Spacer(minLength: 0)
            Label("仅保存额度摘要，不读取密码、令牌或对话正文。", systemImage: "lock.shield")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(22).frame(width: 430).frame(minHeight: 360).background(.white)
    }
}

