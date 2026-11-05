// Compile the standalone sources and Shared/QuotaCard.swift with
// -D YULIANG_STANDALONE -D QUOTA_SHELL_TESTING, plus this file.
// Uses only explicit synthetic snapshots and a temporary local store.
// Never starts the collector, reads authentication, or changes a user's quota file.
import AppKit
import Foundation
import QuotaCore

private struct InteractionVerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw InteractionVerificationFailure(description: message) }
}

@MainActor
private final class InteractionRig {
    let directory: URL
    let model: StandaloneModel
    let base: Date
    let reset: Date

    init(parent: URL, name: String) throws {
        directory = parent.appendingPathComponent(name, isDirectory: true)
        let store = StandaloneQuotaStore(directory: directory)
        base = Date().addingTimeInterval(-180)
        reset = Date().addingTimeInterval(3_600)
        model = StandaloneModel(store: store)
        try expect(!model.collector.isRunning && !model.collector.isBusy
                   && !model.claudeCollector.isRunning && !model.claudeCollector.isBusy,
                   "隔离模型不得启动任何平台的采集")
    }

    func snapshot(_ remaining: Double?, seconds: TimeInterval = 0, reset: Date? = nil,
                  secondary: Double? = 50) -> SnapshotEnvelope {
        let observed = base.addingTimeInterval(seconds)
        return SnapshotEnvelope(providerId: .codex, pageKind: "rate-limits", observedAt: observed,
            source: "codex-app-server", windows: [
                QuotaWindow(id: "primary", label: "5小时额度", usedPercent: remaining.map { 100 - $0 },
                            resetAt: reset ?? self.reset, observedAt: observed),
                QuotaWindow(id: "secondary", label: "7天额度", usedPercent: secondary.map { 100 - $0 },
                            resetAt: reset ?? self.reset, observedAt: observed)
            ], id: "interaction-fixture")
    }

    func claudeSnapshot(_ remaining: Double?, seconds: TimeInterval = 0,
                        reset: Date? = nil, weekly: Double? = 50) -> SnapshotEnvelope {
        let observed = base.addingTimeInterval(seconds)
        return SnapshotEnvelope(providerId: .claude, pageKind: "usage", observedAt: observed,
            source: "browser", windows: [
                QuotaWindow(id: "session", label: "当前会话", usedPercent: remaining.map { 100 - $0 },
                            resetAt: reset ?? self.reset, observedAt: observed),
                QuotaWindow(id: "weekly", label: "每周全部模型", usedPercent: weekly.map { 100 - $0 },
                            resetAt: reset ?? self.reset, observedAt: observed)
            ], id: "claude-interaction-fixture")
    }

    func accept(_ snapshot: SnapshotEnvelope, now: Date? = nil) throws {
        if let now {
            try model.shellTestReceiveSnapshot(snapshot, now: now)
        } else {
            let callback = snapshot.providerId == .claude
                ? model.claudeCollector.onSnapshot : model.collector.onSnapshot
            guard let callback else {
                throw InteractionVerificationFailure(description: "模型未连接快照回调")
            }
            try callback(snapshot)
        }
        try expect(!model.collector.isRunning && !model.collector.isBusy
                   && !model.claudeCollector.isRunning && !model.claudeCollector.isBusy,
                   "合成回调不得启动任一平台的真实采集")
    }

    func tokens(total: Int64, daily: Int64, seconds: TimeInterval = 0,
                day: String = "2026-11-05") throws -> TokenUsageSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": ["lifetimeTokens": total],
            "dailyUsageBuckets": [["startDate": day, "tokens": daily]]
        ])
        return try TokenUsageSnapshot.decode(data, observedAt: base.addingTimeInterval(seconds))
    }

    var value: QuotaPresentation { QuotaPresentation(document: model.document) }
}

@main
struct StandaloneInteractionVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("yuliang-interaction-check-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try run(directory: root)
            print("Standalone互动隔离验证通过：23组。仅使用合成额度和临时存储，未启动平台采集或读取认证。")
            print("Standalone宠物隔离验证通过：7组。照顾、Token成长、切换、皮肤、损坏恢复、存储失败和额度联动均使用临时文件。")
        } catch {
            fputs("Standalone互动隔离验证失败：\(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run(directory: URL) throws {
        // 1. First load is quiet. A confirmed 80% -> 79% decrease feeds once.
        do {
            let rig = try InteractionRig(parent: directory, name: "confirmed-decrease")
            try rig.accept(rig.snapshot(80))
            try expect(rig.model.buddyActivity == nil, "首次读取不能误演吃饼干")
            try rig.accept(rig.snapshot(79, seconds: 1))
            try expect(rig.value.remainingPercent == 79, "确认下降必须保存真实79%")
            try expect(rig.model.buddyActivity?.action == .eating, "确认下降应触发吃饼干")
            try expect(rig.model.buddyActivity?.source == .usage, "自动吃饼干应标为真实用量事件")
            let event = rig.model.buddyActivity?.id
            let records = rig.model.document.records
            rig.model.pat()
            rig.model.feed()
            try expect(rig.model.buddyActivity?.id == event, "真实用量吃饼干期间，点击和手动喂不能中断动作")
            try expect(rig.model.document.records == records, "娱乐点击不能修改真实消耗记录")
            try rig.accept(rig.snapshot(79, seconds: 1))
            try expect(rig.model.buddyActivity?.id == event, "重放同快照不得重演")
            try rig.accept(rig.snapshot(79, seconds: 2))
            try expect(rig.model.buddyActivity?.id == event, "相同百分比的新读取只能推进读取时间")
        }

        // 2. Old/conflicting records cannot fabricate another meal or quota move.
        do {
            let rig = try InteractionRig(parent: directory, name: "old-record")
            try rig.accept(rig.snapshot(80, seconds: 2))
            try rig.accept(rig.snapshot(79, seconds: 3))
            let event = rig.model.buddyActivity?.id
            let records = rig.model.document.records
            try rig.accept(rig.snapshot(60, seconds: 1))
            try rig.accept(rig.snapshot(50, seconds: 3))
            try expect(rig.model.document.records == records, "旧记录和同时间冲突不能覆盖真实记录")
            try expect(rig.model.buddyActivity?.id == event, "旧记录和冲突不能产生新互动")
        }

        // 3. Unknown -> known establishes a baseline; only its next decrease eats.
        do {
            let rig = try InteractionRig(parent: directory, name: "unknown")
            try rig.accept(rig.snapshot(nil))
            try expect(rig.value.remainingPercent == nil, "未知额度不得补出假百分比")
            try expect(rig.model.buddyActivity == nil, "未知额度不得喂食")
            try rig.accept(rig.snapshot(79, seconds: 1))
            try expect(rig.model.buddyActivity == nil, "未知转已知不能推断消耗")
            try rig.accept(rig.snapshot(78, seconds: 2))
            try expect(rig.model.buddyActivity?.action == .eating, "已建立基线后的下降应吃饼干")
        }

        // 4. A changed reset cycle and a recovery are not consumption.
        do {
            let rig = try InteractionRig(parent: directory, name: "reset-and-recovery")
            try rig.accept(rig.snapshot(80))
            let nextReset = rig.reset.addingTimeInterval(3_600)
            try rig.accept(rig.snapshot(79, seconds: 1, reset: nextReset))
            try expect(rig.model.buddyActivity == nil, "重置周期变化不能误算成饼干")
            try rig.accept(rig.snapshot(90, seconds: 2, reset: nextReset))
            try expect(rig.model.buddyActivity == nil, "额度回升不能触发吃饼干")
            try rig.accept(rig.snapshot(89, seconds: 3, reset: nextReset))
            try expect(rig.model.buddyActivity?.source == .usage, "新周期建立基线后的真实下降应喂食")
        }

        // 5. Changing the selected quota window alone never constitutes usage.
        do {
            let rig = try InteractionRig(parent: directory, name: "selected-window")
            try rig.accept(rig.snapshot(80, secondary: 50))
            rig.model.preference { $0.windowId = "secondary" }
            try expect(rig.model.buddyActivity == nil, "切换额度窗口不能被当作消耗")
            try expect(rig.value.remainingPercent == 50, "应准确显示被选择窗口")
            try rig.accept(rig.snapshot(79, seconds: 1, secondary: 49))
            try expect(rig.value.remainingPercent == 49, "新快照保持所选窗口")
            try expect(rig.model.buddyActivity?.source == .usage, "所选窗口真实下降应吃饼干")
        }

        // 6. Stale/reset-due baselines cannot authorize a consumption animation.
        do {
            let stale = try InteractionRig(parent: directory, name: "stale-baseline")
            try stale.accept(stale.snapshot(80, seconds: -7 * 3_600))
            try expect(stale.value.freshness == .stale, "合成基线应为陈旧记录")
            try stale.accept(stale.snapshot(79, seconds: 1))
            try expect(stale.model.buddyActivity == nil, "陈旧基线更新不能推断本次消耗")
            let due = try InteractionRig(parent: directory, name: "reset-due")
            let pastReset = Date().addingTimeInterval(-60)
            try due.accept(due.snapshot(80, reset: pastReset))
            try due.accept(due.snapshot(79, seconds: 1, reset: pastReset))
            try expect(due.value.freshness == .resetDue, "到期额度保留待核对状态")
            try expect(due.value.remainingPercent == 79, "到期不自动回满")
            try expect(due.model.buddyActivity == nil, "待核对周期不触发真实用量互动")
        }

        // 7. Manual feeding is explicitly play and leaves quota/timestamps alone.
        do {
            let rig = try InteractionRig(parent: directory, name: "manual-feed")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            rig.model.feed()
            try expect(rig.model.buddyActivity?.action == .eating, "手动喂食应出现吃饼干动作")
            try expect(rig.model.buddyActivity?.source == .play, "手动喂食必须标为娱乐互动")
            try expect(rig.model.document.records == records, "手动喂食不改变真实额度或读取时间")
            try expect(try rig.model.store.read().records == records, "手动互动不能污染磁盘额度")
        }

        // 8. Repeated taps offer variety; switching characters clears the old act.
        do {
            let rig = try InteractionRig(parent: directory, name: "tap-and-switch")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let allowed = Set(BuddyAction.playfulActions)
            try expect(allowed.isSuperset(of: [.jump, .dance, .spin]), "随机互动池应包含新增的跳跃、摇摆和转圈")
            try expect(!allowed.contains(.eating) && !allowed.contains(.idle), "随机点击不能制造进食或空闲事件")
            var last: BuddyAction?
            var lastActivityID: UUID?
            for _ in 0..<12 {
                rig.model.pat()
                let action = rig.model.buddyActivity?.action
                if let care = rig.model.buddyActivity?.petCare {
                    try expect(action == care.buddyAction && rig.model.buddyActivity?.source == .play,
                               "点击发现的照顾应带明确动作标识，娱乐水果不冒充真实消耗")
                } else {
                    try expect(action.map { allowed.contains($0) } == true, "普通点击应从可选娱乐动作中选择")
                }
                try expect(action != last, "照顾与普通互动连续点击不能重复同一动作")
                try expect(rig.model.buddyActivity?.id != lastActivityID, "每次点击应有实际可见的动作回应")
                last = action
                lastActivityID = rig.model.buddyActivity?.id
            }
            try expect(rig.model.document.records == records, "摸头等娱乐互动不修改真实额度")
            let character = rig.model.document.preferences.character
            rig.model.switchCharacter()
            try expect(rig.model.document.preferences.character != character, "切换角色应保存选择")
            try expect(rig.model.buddyActivity?.action == .wave, "新角色应挥手而非继承旧动作")
            try expect(rig.model.document.records == records, "换角色不得改变额度或读取时间")
        }

        // 9. If durable storage rejects a snapshot, it cannot trigger a meal.
        do {
            let rig = try InteractionRig(parent: directory, name: "store-failure")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let file = rig.directory.appendingPathComponent("quota.json")
            try Data("{broken-fixture".utf8).write(to: file, options: .atomic)
            var rejected = false
            do { try rig.accept(rig.snapshot(79, seconds: 1)) }
            catch { rejected = true }
            try expect(rejected, "坏的本地存储应拒绝写入")
            try expect(rig.model.document.records == records, "写入失败不能先更新UI额度")
            try expect(rig.model.buddyActivity == nil, "写入失败不能先演吃饼干")
            try expect(try Data(contentsOf: file) == Data("{broken-fixture".utf8), "失败必须保留原文件")
        }

        // 10. Every built-in buddy can be selected, persisted and restored. A
        // complete cycle returns to its starting point without touching quota.
        do {
            let rig = try InteractionRig(parent: directory, name: "character-catalog")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let expected: Set<QuotaCharacter> = [.dragonGirl, .claudeGirl, .deepseekGirl, .geminiGirl,
                .cloudSprite, .nailong, .swordCat]
            try expect(Set(rig.model.availableCharacters) == expected, "公开版应包含七个可选伙伴，不能依赖私有旧图集")
            for character in QuotaCharacter.builtInCharacters {
                rig.model.selectCharacter(character)
                try expect(rig.model.document.preferences.character == character, "选择角色应直接命中所选伙伴")
                try expect(try rig.model.store.read().preferences.character == character, "角色选择必须持久保存")
                let restored = StandaloneModel(store: rig.model.store)
                try expect(restored.document.preferences.character == character, "重新创建模型应恢复选择")
                try expect(restored.document.records == records, "选择或恢复伙伴不能改写额度与读取时间")
            }
            rig.model.selectCharacter(.dragonGirl)
            let start = rig.model.document.preferences.character
            var visited = Set<QuotaCharacter>()
            for _ in 0..<rig.model.availableCharacters.count {
                rig.model.switchCharacter()
                visited.insert(rig.model.document.preferences.character)
            }
            try expect(rig.model.document.preferences.character == start && visited == expected,
                       "循环切换必须经过七个伙伴并回到起点")
            rig.model.selectCharacter(.kuromi)
            try expect(rig.model.document.preferences.character == start, "缺少私有资源的旧角色不能被选中")
            for removed in [QuotaCharacter.mochiCat, .butterBunny, .mintFox, .sesameBear] {
                rig.model.selectCharacter(removed)
                try expect(rig.model.document.preferences.character == start, "移出的伙伴不可重新选中")
            }
            try expect(rig.model.document.records == records, "完整角色循环不改变真实额度")
        }

        // 11. Explicit play controls produce the requested action, stay local,
        // and cannot interrupt a confirmed usage meal, even across buddy changes.
        do {
            let rig = try InteractionRig(parent: directory, name: "explicit-play")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let actions = BuddyAction.interactiveActions
            try expect(Set(actions).isSuperset(of: [.jump, .dance, .spin, .eating]), "显式动作菜单应包含新增动作和喂食")
            for action in actions {
                rig.model.play(action)
                try expect(rig.model.buddyActivity?.action == action, "显式互动按钮应播放所选动作")
                try expect(rig.model.buddyActivity?.source == .play, "显式互动必须标为娱乐")
                try expect(rig.model.buddyActivity?.duration == action.duration, "每种动作应按其有限时长结束")
                try expect(rig.model.document.records == records, "显式互动不能改额度与采样时间")
                try expect(try rig.model.store.read().records == records, "显式互动不能向磁盘写入假消耗")
            }
            let playID = rig.model.buddyActivity?.id
            rig.model.play(.idle)
            try expect(rig.model.buddyActivity?.id == playID, "空闲动作不能制造新互动")
            try rig.accept(rig.snapshot(79, seconds: 1))
            let usageID = rig.model.buddyActivity?.id
            let usedRecords = rig.model.document.records
            try expect(rig.model.buddyActivity?.source == .usage, "真实下降必须优先替换娱乐动作")
            for action in actions { rig.model.play(action) }
            rig.model.selectCharacter(.deepseekGirl)
            try expect(rig.model.document.preferences.character == .deepseekGirl, "进食时仍可更换伙伴")
            try expect(rig.model.buddyActivity?.id == usageID && rig.model.buddyActivity?.source == .usage,
                       "显式动作或更换伙伴不能打断真实用量进食")
            try expect(rig.model.document.records == usedRecords, "进食互动控制不能篡改已确认额度")
        }

        // 12. Restoring an already observed account shows encouragement, not a
        // timestamp flash; wall-clock presentation updates cannot shuffle it.
        do {
            let rig = try InteractionRig(parent: directory, name: "feedback-restored")
            try rig.accept(rig.snapshot(80))
            let restored = StandaloneModel(store: rig.model.store)
            let records = restored.document.records
            let initial = restored.feedbackMessage
            try expect(initial.kind == .encouragement, "持久快照初始化不能闪更新时间或常驻时间")
            try expect(restored.buddyFeedback.lastObservedAt == QuotaPresentation(document: restored.document).observedAt,
                       "持久快照应建立去重基线")
            try expect(restored.buddyFeedback.nextTransition(after: restored.now) == nil,
                       "恢复快照不应创建刷新倒计时")
            restored.now = restored.now.addingTimeInterval(60)
            restored.appearance = .dark
            restored.showDailyTokens = false
            try expect(restored.feedbackMessage == initial, "时钟、外观或显示开关不应重排激励或制造刷新")
            try expect(restored.document.records == records, "恢复和显示更新不能改变额度数据")
            try expect(!restored.collector.isRunning && !restored.collector.isBusy, "恢复模型不能自动启动真实采集")
        }

        // 13. The animation can finish at 2.4s while its encouragement remains
        // readable for 5.5s. Advance the model clock without real timer waits.
        do {
            let rig = try InteractionRig(parent: directory, name: "feedback-play-reading-time")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            rig.model.play(.pat)
            let start = rig.model.now
            let response = rig.model.feedbackMessage
            try expect(response.kind == .interaction && !response.text.isEmpty, "手动互动应立即给出激励回应")
            try expect(response.text.count <= 20, "激励句应适配两行小组件反馈区")
            try expect(rig.model.buddyActivity?.duration == 2.4, "摸头动作应保持原有有限动画时长")
            rig.model.now = start.addingTimeInterval(3)
            rig.model.buddyActivity = nil // The same cleanup performed by the model's clock.
            try expect(rig.model.feedbackMessage == response, "2.4秒动作结束不能过早移除激励文案")
            rig.model.now = start.addingTimeInterval(5.499)
            try expect(rig.model.feedbackMessage == response, "激励回应应留足5.5秒阅读时间")
            rig.model.now = start.addingTimeInterval(5.5)
            try expect(rig.model.feedbackMessage.kind == .encouragement, "阅读期结束后应恢复日常激励而非更新时间")
            try expect(rig.model.document.records == records, "激励与动作结束均不应修改额度或读取时间")
        }

        // 14. A real ingestion path with a newer official observation flashes
        // its exact update time, then returns to encouragement after 2.4s.
        do {
            let rig = try InteractionRig(parent: directory, name: "feedback-fresh-observation")
            try rig.accept(rig.snapshot(80))
            let originalObservation = rig.value.observedAt
            try rig.accept(rig.snapshot(80, seconds: 1))
            let start = rig.model.now
            let observed = rig.value.observedAt
            let response = rig.model.feedbackMessage
            try expect(observed != nil && observed! > originalObservation!, "可信刷新应实际接收更晚的采样时间")
            try expect(response.kind == .refresh, "新可信采样应通过collector回调短显更新时间")
            try expect(response.text.contains(observed!.formatted(date: .omitted, time: .standard)),
                       "刷新短显必须使用实际接收的额度采样时间")
            try expect(rig.model.buddyActivity == nil && rig.value.remainingPercent == 80,
                       "相同额度的成功刷新只显示读取反馈，不能制造进食或消耗")
            rig.model.now = start.addingTimeInterval(2.399)
            try expect(rig.model.feedbackMessage.kind == .refresh, "更新时间不能闪得无法读到")
            rig.model.now = start.addingTimeInterval(2.4)
            let idle = rig.model.feedbackMessage
            try expect(idle.kind == .encouragement, "2.4秒后更新时间应让位给日常激励")
            rig.model.now = start.addingTimeInterval(60)
            try expect(rig.model.feedbackMessage == idle, "无新事件时激励应稳定，更新时间不能重新出现")
        }

        // 15. Replay the collector callback against a persisted baseline. No
        // elapsed-time sleep is needed to prove old data cannot start a flash.
        do {
            let rig = try InteractionRig(parent: directory, name: "feedback-no-replay")
            try rig.accept(rig.snapshot(80, seconds: 2))
            let restored = StandaloneModel(store: rig.model.store)
            guard let callback = restored.collector.onSnapshot else {
                throw InteractionVerificationFailure(description: "恢复模型应保留合成采集回调")
            }
            let feedback = restored.buddyFeedback
            let records = restored.document.records
            try callback(rig.snapshot(80, seconds: 2))
            try callback(rig.snapshot(60, seconds: 1))
            try callback(rig.snapshot(50, seconds: 2))
            try expect(restored.feedbackMessage.kind == .encouragement, "重复、旧或同时间冲突快照不能再闪更新时间")
            try expect(restored.buddyFeedback == feedback, "被拒绝的重放不能更改激励序号或刷新截止时间")
            try expect(restored.document.records == records, "旧回调不能覆盖已保存额度")
            try expect(!restored.collector.isRunning && !restored.collector.isBusy, "回放检查不能启动Codex采集")
        }

        // 16. Persistent collection errors have higher priority than idle,
        // refresh and interaction messages, so friendly copy cannot hide them.
        do {
            let rig = try InteractionRig(parent: directory, name: "feedback-error-priority")
            try rig.accept(rig.snapshot(80))
            rig.model.error = "合成读取失败"
            try expect(rig.model.feedbackMessage.kind == .error, "读取错误必须覆盖刷新成功短显")
            rig.model.play(.celebrate)
            let start = rig.model.now
            try expect(rig.model.feedbackMessage.kind == .error, "互动激励不能覆盖实际读取错误")
            try expect(rig.model.feedbackMessage.text.contains("读取失败"), "错误反馈应保留可发现的失败说明")
            rig.model.error = nil
            try expect(rig.model.feedbackMessage.kind == .interaction, "错误解除后应保留仍在阅读期内的互动回应")
            rig.model.now = start.addingTimeInterval(6)
            try expect(rig.model.feedbackMessage.kind == .encouragement, "互动结束后应恢复日常鼓励")
            rig.model.error = "合成持续读取失败"
            try expect(rig.model.feedbackMessage.kind == .error, "持续错误不能被日常鼓励隐藏")

            // Exercise actual collector failure paths without launching a CLI.
            rig.model.error = nil
            let callback = rig.model.collector.onSnapshot
            rig.model.collector.onSnapshot = nil
            rig.model.collector.start()
            try expect(rig.model.collector.quotaError != nil, "无法连接存储时必须暴露额度采集错误")
            try expect(!rig.model.collector.isRunning && !rig.model.collector.isBusy,
                       "缺少存储回调的失败检查不得尝试启动真实Codex")
            rig.model.collector.onSnapshot = callback
            let records = rig.model.document.records
            rig.model.collector.shellTestReceiveQuota(nil, observedAt: rig.base.addingTimeInterval(1))
            try expect(rig.model.collector.quotaError != nil, "额度暂不可读时应保留独立的额度错误")
            try expect(rig.model.feedbackMessage.kind == .error, "原额度仍新鲜时，采集失败也不能被鼓励隐藏")
            try expect(rig.model.document.records == records, "失败采集必须保留上次有效额度")
            let failure = rig.model.collector.quotaError
            rig.model.collector.pause()
            try expect(rig.model.collector.quotaError == failure, "暂停状态不能清掉尚未解决的具体错误")
            rig.model.collector.shellTestReceiveQuota(Data("{broken-fixture".utf8),
                                                     observedAt: rig.base.addingTimeInterval(2))
            try expect(rig.model.collector.quotaError != nil, "不可验证的额度响应不能清除错误")
            let valid = try JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 20, "windowDurationMins": 300,
                            "resetsAt": Int(rig.reset.timeIntervalSince1970)],
                "secondary": ["usedPercent": 50, "windowDurationMins": 10_080,
                              "resetsAt": Int(rig.reset.timeIntervalSince1970)]
            ]]])
            rig.model.collector.shellTestReceiveQuota(valid, observedAt: rig.base.addingTimeInterval(3))
            try expect(rig.model.collector.quotaError == nil, "可验证的新额度成功保存后才清除额度错误")
            try expect(rig.model.collector.tokenUsageState == .unsupported,
                       "Token接口不可用状态应独立保留，不能伪称Token也成功")
            try expect(rig.model.feedbackMessage.kind != .error, "额度恢复后，独立的Token不支持不能继续遮挡额度激励")
            rig.model.collector.onSnapshot = { _ in throw InteractionVerificationFailure(description: "合成存储拒绝") }
            rig.model.collector.shellTestReceiveQuota(valid, observedAt: rig.base.addingTimeInterval(4))
            try expect(rig.model.collector.quotaError?.contains("保存失败") == true,
                       "存储拒绝不能报告额度刷新成功或清空错误")
            rig.model.collector.onSnapshot = callback
            rig.model.collector.shellTestReceiveQuota(valid, observedAt: rig.base.addingTimeInterval(5))
            try expect(rig.model.collector.quotaError == nil && !rig.model.collector.isRunning && !rig.model.collector.isBusy,
                       "恢复成功应清除额度错误，所有验证仍不得启动真实采集")
        }

        // 17. Selecting an unconnected Claude account cannot borrow a Codex
        // quota, error or token claim, and the provider choice survives restart.
        do {
            let rig = try InteractionRig(parent: directory, name: "provider-empty-isolation")
            try rig.accept(rig.snapshot(80))
            let tokens = try TokenUsageSnapshot.decode(Data("{\"summary\":{\"lifetimeTokens\":12345},\"dailyUsageBuckets\":[{\"startDate\":\"2026-11-04\",\"tokens\":321}]}".utf8),
                                                       observedAt: rig.base)
            rig.model.collector.shellTestSetTokenUsage(tokens)
            rig.model.collector.shellTestReceiveQuota(nil, observedAt: rig.base.addingTimeInterval(1))
            try expect(rig.model.collector.quotaError != nil && rig.model.collector.tokenUsage != nil,
                       "空状态隔离检查必须先建立独立的Codex错误与Token记录")
            let records = rig.model.document.records
            rig.model.selectProvider(.claude)
            try expect(rig.value.provider == .claude && rig.value.remainingPercent == nil && rig.value.window == nil,
                       "未连接Claude应保留未知额度，不能复用Codex窗口")
            try expect(rig.model.selectedQuotaError == nil && !rig.model.selectedBusy,
                       "Claude选择状态不得继承Codex采集错误或忙碌状态")
            let emptyMessage = rig.model.feedbackMessage.text
            try expect(emptyMessage.contains("Claude") && !emptyMessage.contains("Codex")
                       && !emptyMessage.localizedCaseInsensitiveContains("token"),
                       "Claude空状态应只引导连接Claude，不泄露Codex用量或错误提示")
            try expect(rig.model.buddyActivity == nil && rig.model.document.records == records,
                       "切换平台不能制造互动或改写真实记录")
            let restored = StandaloneModel(store: rig.model.store)
            try expect(restored.document.preferences.providerId == .claude
                       && QuotaPresentation(document: restored.document).remainingPercent == nil,
                       "重新创建模型应恢复Claude选择与未知额度")
            rig.model.selectProvider(.chatgpt)
            try expect(rig.value.provider == .claude, "未接入的平台不能成为可读额度来源")
            try expect(!restored.collector.isRunning && !restored.claudeCollector.isRunning,
                       "恢复Claude选择不得自行发起采集")
        }

        // 18. Background Codex records remain durable while Claude is selected;
        // only an actual decrease in the selected Claude cycle starts a meal.
        do {
            let rig = try InteractionRig(parent: directory, name: "claude-selected-background-codex")
            try rig.accept(rig.snapshot(80))
            rig.model.selectProvider(.claude)
            try rig.accept(rig.claudeSnapshot(65))
            try expect(rig.value.remainingPercent == 65 && rig.model.buddyActivity == nil,
                       "Claude首次真实额度建立基线，不能追补一次进食")
            rig.model.play(.nuzzle)
            let activity = rig.model.buddyActivity?.id
            let feedback = rig.model.buddyFeedback
            try rig.accept(rig.snapshot(60, seconds: 60))
            try expect(rig.value.provider == .claude && rig.value.remainingPercent == 65,
                       "后台Codex下降不能移动前台Claude进度")
            try expect(rig.model.buddyActivity?.id == activity && rig.model.buddyFeedback == feedback,
                       "后台平台更新不得打断前台互动或闪更新时间")
            try rig.accept(rig.claudeSnapshot(64, seconds: 1))
            try expect(rig.value.remainingPercent == 64 && rig.model.buddyActivity?.source == .usage
                       && rig.model.buddyActivity?.action == .eating
                       && rig.model.buddyActivity?.consumedPercent == 1,
                       "Claude同周期已确认下降应通过真实回调喂一块饼干")
            rig.model.selectProvider(.codex)
            try expect(rig.value.remainingPercent == 60 && rig.model.buddyActivity == nil,
                       "后台Codex记录应保存，切回时只显示基线而不补播消耗")
        }

        // 19. The reverse direction is isolated too, including an independent
        // Claude reset cycle, and switching never replays a timestamp flash.
        do {
            let rig = try InteractionRig(parent: directory, name: "codex-selected-background-claude")
            try rig.accept(rig.snapshot(80))
            try rig.accept(rig.claudeSnapshot(85))
            rig.model.play(.wave)
            let activity = rig.model.buddyActivity?.id
            let feedback = rig.model.buddyFeedback
            try rig.accept(rig.claudeSnapshot(84, seconds: 1))
            try expect(rig.value.provider == .codex && rig.value.remainingPercent == 80,
                       "后台Claude下降不能污染前台Codex额度")
            try expect(rig.model.buddyActivity?.id == activity && rig.model.buddyFeedback == feedback,
                       "后台Claude更新不应触发前台进食或反馈")
            rig.model.selectProvider(.claude)
            try expect(rig.value.remainingPercent == 84 && rig.model.buddyActivity == nil
                       && rig.model.feedbackMessage.kind == .encouragement,
                       "切回Claude仅恢复已存基线，不回放刷新和互动")
            try expect(rig.model.buddyFeedback.lastObservedAt == rig.value.observedAt,
                       "平台切换应把所选平台观测时间作为去重基线")
            try rig.accept(rig.claudeSnapshot(83, seconds: 2, reset: rig.reset.addingTimeInterval(3_600)))
            try expect(rig.model.buddyActivity == nil, "Claude重置周期变化不能被误判为消耗")
            try rig.accept(rig.claudeSnapshot(82, seconds: 3, reset: rig.reset.addingTimeInterval(3_600)))
            try expect(rig.model.buddyActivity?.source == .usage,
                       "Claude新周期建立基线后的真实下降应正常触发互动")
        }

        // 20. A single model clock drives quiet, deterministic autonomous acts
        // without a collector, a second view, or fabricated quota consumption.
        do {
            let rig = try InteractionRig(parent: directory, name: "companion-clock")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let start = rig.model.now
            rig.model.shellTestResetCompanion(now: start, seed: 42)
            var moments: [(second: Int, action: BuddyAction)] = []
            var previousID: UUID?
            for second in 1...300 {
                rig.model.advanceClock(to: start.addingTimeInterval(Double(second)))
                if let activity = rig.model.buddyActivity, activity.id != previousID {
                    try expect(activity.source == .companion && activity.action != .eating && activity.action != .idle,
                               "自主动作必须独立标记，不能伪造真实进食")
                    try expect(!rig.model.feedbackMessage.text.isEmpty
                               && rig.model.feedbackMessage.kind == .encouragement,
                               "自主活动应带有可读的轻声关怀，而非虚假刷新提示")
                    moments.append((second, activity.action))
                    previousID = activity.id
                }
            }
            try expect((8...11).contains(moments.count), "五分钟内自主活动应维持大约每30秒一次")
            try expect(moments.first.map { (26...34).contains($0.second) } == true,
                       "初次自主活动应安静等待26至34秒")
            for index in 1..<moments.count {
                try expect((26...34).contains(moments[index].second - moments[index - 1].second),
                           "后续自主活动应间隔约30秒")
                try expect(moments[index].action != moments[index - 1].action,
                           "连续自主活动不应重复同一动作")
            }
            let persisted = try rig.model.store.read().records
            try expect(rig.model.document.records == records && persisted == records,
                       "自主关怀不得改动额度、Token用量或采样时间")
            try expect(!rig.model.collector.isRunning && !rig.model.claudeCollector.isRunning,
                       "自主陪伴不能暗中启动账号读取")
        }

        // 21. Hidden, sleeping, disabled, reduced-motion and settings surfaces
        // remain quiet. Resuming never replays a backlog of autonomous actions.
        do {
            for mode in ["hidden", "sleeping", "disabled", "reduced-motion", "settings"] {
                let rig = try InteractionRig(parent: directory, name: "companion-quiet-\(mode)")
                try rig.accept(rig.snapshot(80))
                let records = rig.model.document.records
                let start = rig.model.now
                rig.model.shellTestResetCompanion(now: start, seed: 42, reduceMotion: mode == "reduced-motion")
                rig.model.companionVisible = mode != "hidden"
                rig.model.companionSleeping = mode == "sleeping"
                rig.model.companionEnabled = mode != "disabled"
                let settingsSurface = NSObject()
                if mode == "settings" { StandaloneMenuTracking.began(settingsSurface) }
                defer { if mode == "settings" { StandaloneMenuTracking.ended(settingsSurface) } }
                for second in 1...180 {
                    rig.model.advanceClock(to: start.addingTimeInterval(Double(second)))
                    try expect(rig.model.buddyActivity == nil, "\(mode)期间不得触发自主动作")
                }
                rig.model.companionVisible = true
                rig.model.companionSleeping = false
                rig.model.companionEnabled = true
                if mode == "settings" { StandaloneMenuTracking.ended(settingsSurface) }
                if mode == "reduced-motion" {
                    rig.model.shellTestResetCompanion(now: start.addingTimeInterval(180), seed: 42)
                }
                // Settings are busy rather than paused, so their next act waits
                // at least 12 seconds after the last busy tick. Other surfaces
                // restart a complete 26–34-second quiet interval.
                let quietEnd = mode == "settings" ? 191 : 205
                for second in 181...quietEnd {
                    rig.model.advanceClock(to: start.addingTimeInterval(Double(second)))
                    try expect(rig.model.buddyActivity == nil, "\(mode)恢复后应先安静等待，不补播积压活动")
                }
                var resumed = false
                for second in (quietEnd + 1)...242 {
                    rig.model.advanceClock(to: start.addingTimeInterval(Double(second)))
                    resumed = resumed || rig.model.buddyActivity?.source == .companion
                }
                try expect(resumed, "\(mode)恢复并经过安静等待后应可再次陪伴")
                try expect(rig.model.document.records == records, "静默和恢复不能产生假额度记录")
            }
        }

        // 22. Explicit play takes priority over autonomous company and starts
        // a new cooldown; a genuine quota decrease still outranks both.
        do {
            let rig = try InteractionRig(parent: directory, name: "companion-manual-priority")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let start = Date()
            rig.model.shellTestResetCompanion(now: start, seed: 42)
            let moment = BuddyCompanionMoment(action: .peek, caption: "探个头，陪你慢慢来")
            rig.model.buddyActivity = BuddyActivity(action: .peek, startedAt: start, source: .companion)
            rig.model.buddyFeedback = BuddyFeedbackState(observedAt: rig.value.observedAt)
            let accepted = rig.model.buddyFeedback.accompany(moment, now: start)
            try expect(accepted, "优先级检查应先建立自主动作与文案")
            rig.model.play(.nuzzle)
            let playStart = rig.model.now
            let playID = rig.model.buddyActivity?.id
            let response = rig.model.feedbackMessage
            try expect(rig.model.buddyActivity?.source == .play && rig.model.buddyActivity?.action == .nuzzle
                       && response.kind == .interaction,
                       "手动撒娇应立即替换自主动作与文案")
            for second in 1...25 {
                rig.model.advanceClock(to: playStart.addingTimeInterval(Double(second)))
                try expect(rig.model.buddyActivity?.source != .companion,
                           "手动互动后的最短26秒冷却内不得插入自主活动")
                if second <= 2 {
                    try expect(rig.model.buddyActivity?.id == playID && rig.model.feedbackMessage == response,
                               "手动动作与阅读时间应得到优先保留")
                }
            }
            try expect(rig.model.document.records == records, "手动优先与冷却不能修改真实额度")
            try rig.accept(rig.snapshot(79, seconds: 1))
            let usageID = rig.model.buddyActivity?.id
            try expect(rig.model.buddyActivity?.source == .usage && rig.model.buddyActivity?.action == .eating,
                       "确认的真实消耗应优先播放进食")
            rig.model.play(.sip)
            try expect(rig.model.buddyActivity?.id == usageID,
                       "喝水等娱乐互动不能打断真实消耗的进食")
        }

        // 23. Continuous real usage at the collector's 60-second cadence must
        // not starve autonomous company by restarting its roughly 30-second delay.
        // Inject the same past clock into reception and ticking so this catches
        // the old starvation behavior without sleeps or rewriting activities.
        do {
            let rig = try InteractionRig(parent: directory, name: "continuous-usage-allows-company")
            let start = Date().addingTimeInterval(-20 * 60)
            try rig.accept(rig.snapshot(95, seconds: start.timeIntervalSince(rig.base)), now: start)
            rig.model.shellTestResetCompanion(now: start, seed: 42)
            var expectedRecords = rig.model.document.records
            var meals = 0
            var afterUsageMoments = 0
            var previousCompanionID: UUID?
            var lastMealAt: Date?
            for second in 1...660 {
                let date = start.addingTimeInterval(Double(second))
                if second.isMultiple(of: 60), second <= 600 {
                    let remaining = 95 - Double(second / 60)
                    try rig.accept(rig.snapshot(remaining, seconds: date.timeIntervalSince(rig.base)), now: date)
                    try expect(rig.model.buddyActivity?.source == .usage
                               && rig.model.buddyActivity?.action == .eating
                               && rig.model.buddyActivity?.startedAt == date,
                               "每60秒确认一次真实下降应在同一时钟上触发进食")
                    try expect(rig.model.buddyActivity?.consumedPercent == 1,
                               "连续消费每次只按实际下降1%喂食")
                    expectedRecords = rig.model.document.records
                    meals += 1
                    lastMealAt = date
                }
                let before = rig.model.buddyActivity
                rig.model.advanceClock(to: date)
                if let before, before.source == .usage,
                   date.timeIntervalSince(before.startedAt) < before.duration {
                    try expect(rig.model.buddyActivity?.id == before.id,
                               "自主调度不能打断尚未结束的真实进食")
                }
                if let activity = rig.model.buddyActivity, activity.source == .companion,
                   activity.id != previousCompanionID {
                    previousCompanionID = activity.id
                    if let lastMealAt {
                        afterUsageMoments += 1
                        try expect(date.timeIntervalSince(lastMealAt) >= 12,
                                   "真实进食后应留出安静间隔，再恢复自主陪伴")
                    }
                }
                try expect(rig.model.document.records == expectedRecords,
                           "消费间隙的时钟与自主互动不能新增额度消耗或更新时间")
            }
            try expect(meals == 10 && (8...20).contains(afterUsageMoments),
                       "连续每60秒消费时，仍应偶尔自主活动，不能永远只吃饼干")
            try expect(rig.value.remainingPercent == 85, "连续真实下降应仅把95%更新为85%")
            let persisted = try rig.model.store.read().records
            try expect(persisted == expectedRecords, "自主陪伴不能向磁盘补写虚假消费")
        }

        // Pet 1. Actual model care saves its own journal before showing a
        // reward. Immediate repeat/different-action taps cannot farm growth.
        do {
            let rig = try InteractionRig(parent: directory, name: "pet-care-persistence")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            let quotaBytes = try Data(contentsOf: rig.directory.appendingPathComponent("quota.json"))
            rig.model.care(.fruit)
            let pet = rig.model.petProfile
            let activity = rig.model.buddyActivity?.id
            try expect(pet.experience == 3 && pet.careCount == 1 && pet.satiety == 81,
                       "照顾水果应实际改变伙伴状态与有限成长")
            try expect(pet.badges == [.firstCare] && rig.model.buddyActivity?.petCare == .fruit,
                       "首次照顾应解锁一次徽章并播放专属水果动作")
            let petFile = rig.directory.appendingPathComponent("pet.json")
            let bytes = try Data(contentsOf: petFile)
            let disk = try rig.model.petStore.read()
            try expect(disk == rig.model.petState, "显示的成长必须先写入独立宠物文件")
            let restored = StandaloneModel(store: rig.model.store)
            try expect(restored.petState == disk && restored.petProfile == pet,
                       "重启应恢复成长、需要值和徽章，不重复授奖")
            rig.model.care(.fruit)
            rig.model.care(.milk)
            try expect(rig.model.petProfile == pet && rig.model.buddyActivity?.id != activity
                       && rig.model.buddyActivity?.petCare == .milk,
                       "照顾冷却只限制状态与奖励，点击仍应播放所选牛奶互动")
            try expect(rig.model.petCooldown(for: .fruit) > 80 && rig.model.petCooldown(for: .milk) > 0,
                       "照顾冷却应向菜单和面板提供可读取的剩余时间")
            try expect(try Data(contentsOf: petFile) == bytes, "冷却点击不能改写宠物记录")
            try expect(rig.model.document.records == records
                       && (try Data(contentsOf: rig.directory.appendingPathComponent("quota.json"))) == quotaBytes,
                       "照顾、徽章和恢复均不得修改额度文件或采样时间")
        }

        // Pet 2. The collector's real callback path establishes one baseline,
        // then awards only matching fresh deltas. Quota changes earn no XP.
        do {
            let rig = try InteractionRig(parent: directory, name: "pet-token-callback")
            try rig.accept(rig.snapshot(80))
            try rig.accept(rig.snapshot(79, seconds: 1))
            try expect(rig.model.petProfile.experience == 0 && rig.model.petProfile.confirmedTokens == 0,
                       "额度百分比下降只能播放陪伴，不能推算Token或授予成长")
            let records = rig.model.document.records
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 1_000_000, daily: 200_000))
            try expect(rig.model.petProfile.experience == 0 && rig.model.petProfile.badges.isEmpty,
                       "首次Token读取必须仅建基线，不能奖励历史累计")
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 1_010_000, daily: 210_000, seconds: 60))
            let pet = rig.model.petProfile
            try expect(pet.experience == 2 && pet.confirmedTokens == 10_000 && pet.badges == [.tokenGrowth],
                       "同日连续双计数增量应通过真实采集回调累积成长")
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 1_010_000, daily: 210_000, seconds: 60))
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 1_010_000, daily: 210_000, seconds: 61))
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 9_000_000, daily: 8_200_000, seconds: 59))
            try expect(rig.model.petProfile == pet, "重放、旧样本和新时间相同计数不能重复授奖")
            let restored = StandaloneModel(store: rig.model.store)
            restored.collector.shellTestSetTokenUsage(try rig.tokens(total: 1_015_000, daily: 215_000, seconds: 62))
            try expect(restored.petProfile.experience == 3 && restored.petProfile.confirmedTokens == 15_000
                       && restored.petProfile.badges == [.tokenGrowth],
                       "重启后应沿持久基线只奖励新增量，不重领旧Token徽章")
            try expect(restored.document.records == records && rig.model.document.records == records,
                       "Token成长与重启不能改写订阅额度")
            try expect(!restored.collector.isRunning && !restored.collector.isBusy,
                       "合成Token路径不得启动真实平台采集")
        }

        // Pet 3. Profiles belong to their own character. Changing the selected
        // buddy cannot copy XP, cooldowns, badges or replay global Token deltas.
        do {
            let rig = try InteractionRig(parent: directory, name: "pet-character-isolation")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            rig.model.selectCharacter(.dragonGirl)
            rig.model.care(.groom)
            let dragon = rig.model.petProfile
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 0, daily: 0, seconds: 120))
            rig.model.selectCharacter(.swordCat)
            try expect(rig.model.petProfile.experience == 0 && rig.model.petProfile.careCount == 0
                       && rig.model.petProfile.badges.isEmpty && rig.model.petCooldown(for: .groom) == 0,
                       "新选择伙伴应有自己的成长与冷却，而不是继承上一个角色")
            rig.model.care(.rest)
            try expect(rig.model.petProfile.experience == 3
                       && Set(rig.model.petProfile.badges) == Set([.firstCare, .restful]),
                       "另一个伙伴的休息应独立授予照顾和休息徽章")
            rig.model.selectCharacter(.dragonGirl)
            try expect(rig.model.petProfile == dragon, "切回伙伴应恢复它原有的状态与徽章")
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 0, daily: 0, seconds: 120))
            try expect(rig.model.petProfile == dragon, "切换角色不能重复领取旧Token样本")
            try expect(rig.model.document.records == records, "角色成长隔离不得改变额度记录")
        }

        // Pet 4. Locked skins cannot be selected through the model, bypassing
        // the UI. An allowed appearance persists without granting experience.
        do {
            let rig = try InteractionRig(parent: directory, name: "pet-skin-gating")
            try rig.accept(rig.snapshot(80))
            rig.model.care(.highFive)
            let state = rig.model.petState
            let activity = rig.model.buddyActivity?.id
            let bytes = try Data(contentsOf: rig.directory.appendingPathComponent("pet.json"))
            rig.model.choosePetSkin(.starlight)
            rig.model.choosePetSkin(.aurora)
            try expect(rig.model.petState == state && rig.model.petProfile.skin == .natural
                       && rig.model.buddyActivity?.id == activity,
                       "未达等级的皮肤不能由模型入口绕过解锁")
            try expect(try Data(contentsOf: rig.directory.appendingPathComponent("pet.json")) == bytes,
                       "选择锁定皮肤不能写磁盘或偷偷增加经验")
            rig.model.choosePetSkin(.natural)
            try expect(rig.model.petProfile.experience == 3 && rig.model.petProfile.skin == .natural,
                       "已解锁外观只改变穿戴，不能增加成长")
        }

        // Pet 5. A corrupt pet journal is preserved and blocks all pet writes;
        // usable quota and harmless ordinary play still work independently.
        do {
            let petDirectory = directory.appendingPathComponent("pet-corrupt-on-load", isDirectory: true)
            try FileManager.default.createDirectory(at: petDirectory, withIntermediateDirectories: true)
            let petFile = petDirectory.appendingPathComponent("pet.json")
            let broken = Data("{broken-pet-fixture".utf8)
            try broken.write(to: petFile, options: .atomic)
            let rig = try InteractionRig(parent: directory, name: "pet-corrupt-on-load")
            try expect(rig.model.petStorageError != nil, "损坏成长文件必须暴露错误，不静默覆盖")
            try rig.accept(rig.snapshot(80))
            let records = rig.model.document.records
            rig.model.care(.fruit)
            rig.model.choosePetSkin(.natural)
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 1_000, daily: 100))
            rig.model.collector.shellTestSetTokenUsage(try rig.tokens(total: 6_000, daily: 5_100, seconds: 60))
            try expect(try Data(contentsOf: petFile) == broken, "照顾、皮肤和Token回调均不得覆盖损坏的原文件")
            try expect(rig.model.petProfile.experience == 0 && rig.model.petProfile.careCount == 0,
                       "成长无法持久保存时，界面不能先授予经验或徽章")
            rig.model.play(.wave)
            try expect(rig.model.buddyActivity?.action == .wave && rig.model.document.records == records,
                       "成长存储错误不能破坏普通互动或独立的额度记录")
        }

        // Pet 6. If the file cannot be committed, no local reward or visual care
        // is published. The original blocker remains untouched for recovery.
        do {
            let rig = try InteractionRig(parent: directory, name: "pet-write-failure")
            try rig.accept(rig.snapshot(80))
            let petFile = rig.directory.appendingPathComponent("pet.json", isDirectory: true)
            try FileManager.default.createDirectory(at: petFile, withIntermediateDirectories: true)
            let blocker = petFile.appendingPathComponent("preserve-fixture.txt")
            let original = Data("keep-me".utf8)
            try original.write(to: blocker)
            rig.model.care(.playBall)
            try expect(rig.model.petStorageError != nil && rig.model.petProfile.experience == 0
                       && rig.model.petProfile.careCount == 0 && rig.model.buddyActivity == nil,
                       "宠物文件写入失败时不能先播放已保存的照顾或发经验")
            try expect(try Data(contentsOf: blocker) == original, "失败不能清空原有阻挡文件")
            try expect(rig.value.remainingPercent == 80 && (try rig.model.store.read()).records == rig.model.document.records,
                       "宠物写入失败不得污染额度与额度存储")
        }

        // Pet 7. The principal rail follows actual quota in both directions;
        // pet progress is independent. Standard/compact rails and Duo orbit all
        // consume the identical presentation percentage and animation trigger.
        do {
            let rig = try InteractionRig(parent: directory, name: "pet-quota-linked-rail")
            try rig.accept(rig.snapshot(80))
            let before = rig.value.remainingPercent
            try expect(before == 80 && !rig.model.animateQuota, "首次额度建立基线，不能从虚构起点播放消耗")
            let originalPet = rig.model.petProfile
            try rig.accept(rig.snapshot(60, seconds: 1))
            let remaining = rig.value.remainingPercent
            try expect(remaining == 60 && rig.model.animateQuota,
                       "可信80%到60%必须保存实际余量并触发主进度条连续过渡")
            for (width, avatar): (Double, Double) in [(133, 45), (274, 56)] {
                let old = QuotaRailGeometry(width: width, avatarSize: avatar, remainingPercent: before)
                let new = QuotaRailGeometry(width: width, avatarSize: avatar, remainingPercent: remaining)
                try expect(new.fillWidth < old.fillWidth && new.markerCenterX < old.markerCenterX
                           && abs(new.fillWidth - width * 0.6) < 0.000_001
                           && abs(new.markerCenterX - new.fillWidth) < 0.000_001,
                           "标准和紧凑模式的填充与人物应同时沿真实额度边界移动")
            }
            let duoBefore = QuotaDuoGeometry(size: 104, remainingPercent: before)
            let duoAfter = QuotaDuoGeometry(size: 104, remainingPercent: remaining)
            let theta = 0.6 * Double.pi * 2 - Double.pi / 2
            try expect(duoAfter.progress == 60 && duoAfter.isKnown
                       && abs(duoAfter.markerX - (duoAfter.side / 2 + duoAfter.ringDiameter / 2 * cos(theta))) < 0.000_001
                       && abs(duoAfter.markerY - (duoAfter.side / 2 + duoAfter.ringDiameter / 2 * sin(theta))) < 0.000_001
                       && (duoAfter.markerX != duoBefore.markerX || duoAfter.markerY != duoBefore.markerY),
                       "Duo人物轨道端点必须使用同一实际60%额度，不能使用宠物经验或固定位置")
            try expect(rig.model.petProfile == originalPet,
                       "主额度进度下降不能推算Token或给宠物增加经验")
            let ended = rig.model.now.addingTimeInterval(4)
            rig.model.advanceClock(to: ended)
            try expect(rig.model.buddyActivity == nil, "合法消耗的有限进食动作应如期结束")
            try rig.accept(rig.snapshot(100, seconds: 2), now: ended.addingTimeInterval(1))
            try expect(rig.value.remainingPercent == 100 && rig.model.animateQuota
                       && rig.model.buddyActivity == nil,
                       "同周期实际回升100%也应连续更新，但不能当作消耗再喂食")
            let full = QuotaRailGeometry(width: 274, avatarSize: 56, remainingPercent: rig.value.remainingPercent)
            let duoFull = QuotaDuoGeometry(size: 104, remainingPercent: rig.value.remainingPercent)
            try expect(full.fillWidth == 274 && full.markerLeadingX + full.avatarSize == 274
                       && duoFull.progress == 100 && abs(duoFull.markerX - duoFull.side / 2) < 0.000_001
                       && abs(duoFull.markerY - (duoFull.side - duoFull.ringDiameter) / 2) < 0.000_001,
                       "实际100%时主条应填满，人物保持在可见端点，Duo回到满环顶端")
            try expect(rig.model.petProfile == originalPet
                       && (try rig.model.store.read()).records == rig.model.document.records,
                       "额度升降必须真实保存，且始终不污染独立的宠物成长")
        }

    }
}
