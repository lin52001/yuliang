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
        try expect(!model.collector.isRunning && !model.collector.isBusy, "隔离模型不得启动采集")
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

    func accept(_ snapshot: SnapshotEnvelope) throws {
        guard let callback = model.collector.onSnapshot else {
            throw InteractionVerificationFailure(description: "模型未连接快照回调")
        }
        try callback(snapshot)
        try expect(!model.collector.isRunning && !model.collector.isBusy, "合成回调不得启动真实采集")
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
            print("Standalone互动隔离验证通过：16组。仅使用合成额度和临时存储，未启动Codex采集或读取认证。")
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
            for _ in 0..<12 {
                rig.model.pat()
                let action = rig.model.buddyActivity?.action
                try expect(action.map { allowed.contains($0) } == true, "点击应从可选娱乐动作中选择")
                try expect(action != last, "连续点击不能重复同一动作")
                last = action
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
                .mochiCat, .butterBunny, .mintFox, .sesameBear, .cloudSprite]
            try expect(Set(rig.model.availableCharacters) == expected, "公开版应包含九个内置伙伴，不能依赖私有旧图集")
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
                       "循环切换必须经过九个伙伴并回到起点")
            rig.model.selectCharacter(.kuromi)
            try expect(rig.model.document.preferences.character == start, "缺少私有资源的旧角色不能被选中")
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

    }
}
