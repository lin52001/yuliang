// Compile with -D QUOTA_COLLECTOR_TESTING and CodexQuotaCollector.swift.
// Arguments: <fake-codex-app-server.mjs> <temporary directory> <Node executable>.
// All processes use that explicit local fixture.
// No Codex authentication, real server, browser data or application store is read.
import AppKit
import Foundation
import QuotaCore

private struct CodexVerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw CodexVerificationFailure(description: message) }
}

@MainActor
private func waitUntil(_ message: String, timeout: TimeInterval = 5,
                       _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    } while Date() < deadline
    throw CodexVerificationFailure(description: "等待超时：\(message)")
}

private struct CodexFixtureEvent: Decodable {
    let event: String
    let pid: Int
    let at: Double
    let method: String?
    let mode: String?
}

@MainActor
private final class CodexFixtureRig {
    let directory: URL
    let controlURL: URL
    let eventsURL: URL
    var collector: CodexQuotaCollector!
    var records: [SnapshotEnvelope] = []
    var rejectSnapshot = false

    init(script: URL, node: URL, parent: URL, name: String) throws {
        directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controlURL = directory.appendingPathComponent("control.json")
        eventsURL = directory.appendingPathComponent("events.jsonl")
        try Data().write(to: eventsURL)
        try control("valid")
        collector = CodexQuotaCollector(fixtureCommand: node,
                                        arguments: [script.path, controlURL.path, eventsURL.path]) { [weak self] snapshot in
            guard let self else { throw CodexVerificationFailure(description: "测试容器提前释放") }
            if self.rejectSnapshot { throw CodexVerificationFailure(description: "合成本地存储拒绝") }
            self.records.append(try snapshot.validated())
        }
    }

    func control(_ mode: String, used: Double = 35, weekly: Double = 60, delay: Int = 0) throws {
        let data = try JSONSerialization.data(withJSONObject: ["mode": mode, "used": used, "weekly": weekly, "delay": delay])
        try data.write(to: controlURL, options: .atomic)
    }

    func events(_ name: String? = nil) throws -> [CodexFixtureEvent] {
        let data = try String(contentsOf: eventsURL, encoding: .utf8)
        return try data.split(separator: "\n").map {
            try JSONDecoder().decode(CodexFixtureEvent.self, from: Data($0.utf8))
        }.filter { name == nil || $0.event == name }
    }

    func readCount() throws -> Int { try events("readStarted").count }

    func seed() async throws {
        collector.refreshNow()
        try await waitUntil("建立合成成功基线") { self.records.count == 1 }
        collector.pause()
    }

    func latest(_ id: String) -> QuotaWindow? { records.last?.windows.first { $0.id == id } }
}

@main
struct CodexCollectorVerification {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 4 else {
            fputs("参数：<fake-codex-app-server.mjs> <临时目录> <Node可执行文件>\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run(script: URL(fileURLWithPath: CommandLine.arguments[1]),
                              directory: URL(fileURLWithPath: CommandLine.arguments[2]),
                              node: URL(fileURLWithPath: CommandLine.arguments[3]))
                print("Codex Process/Pipe隔离验证通过：9组。全部为本机合成CLI响应，未读取真实认证或真实账户额度。")
                exit(0)
            } catch {
                fputs("Codex采集隔离验证失败：\(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func run(script: URL, directory: URL, node: URL) async throws {
        let root = directory.appendingPathComponent("fixture-data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rigs: [CodexFixtureRig] = []
        defer { rigs.forEach { $0.collector.pause() } }
        func rig(_ name: String) throws -> CodexFixtureRig {
            let value = try CodexFixtureRig(script: script, node: node, parent: root, name: name)
            rigs.append(value)
            return value
        }

        let periodic = try rig("sixty-second")
        periodic.collector.connect()
        try check(periodic.records.isEmpty && !periodic.collector.isRunning, "连接动作不得伪造采样或自行启动循环")
        periodic.collector.start()
        try await waitUntil("首轮真实Process/Pipe读取") { periodic.records.count == 1 }
        let firstDate = periodic.records[0].observedAt
        try await waitUntil("第二轮60秒RPC", timeout: 70) { periodic.records.count == 2 }
        periodic.collector.pause()
        let firstReads = try periodic.events("readStarted")
        try check(firstReads.count == 2, "两次采样必须来自两次真实RPC读取")
        let gap = (firstReads[1].at - firstReads[0].at) / 1000
        try check(gap >= 58 && gap <= 68, "自动RPC读取应约60秒一次，实际\(gap)秒")
        try check(periodic.records[1].observedAt > firstDate, "相同百分比的新响应也必须更新真实读取时间")
        try check(periodic.records.allSatisfy { $0.providerId == .codex && $0.source == "codex-app-server" && $0.pageKind == "rate-limits" }, "必须独立标记Codex数据来源")
        try check(periodic.latest("primary")?.usedPercent == 35 && periodic.latest("secondary")?.usedPercent == 60,
                  "必须优先codex桶，不得误用legacy 77%或其他model 91%")
        try check(try periodic.events("protocolViolation").isEmpty, "initialize与initialized握手必须先于额度读取")
        print("✓ 两次真实Process/Pipe RPC约60秒，相同比例更新时间，优先Codex桶")

        for used in [0.0, 100.0] {
            try periodic.control("valid", used: used)
            let count = periodic.records.count
            periodic.collector.refreshNow()
            try await waitUntil("边界\(used)%") { periodic.records.count == count + 1 }
            try check(periodic.latest("primary")?.usedPercent == used, "0%和100%不可丢失或转未知")
        }
        for mode in ["null", "codexNull", "missingPrimary", "missingSecondary", "nullPrimary", "nullSecondary"] {
            try periodic.control(mode)
            let count = periodic.records.count
            periodic.collector.refreshNow()
            try await waitUntil("未知窗口\(mode)") { periodic.records.count == count + 1 }
            let primaryUnknown = ["null", "codexNull", "missingPrimary", "nullPrimary"].contains(mode)
            let secondaryUnknown = ["null", "codexNull", "missingSecondary", "nullSecondary"].contains(mode)
            try check(periodic.latest("primary") != nil && periodic.latest("secondary") != nil,
                      "空或缺失窗口应有独立unknown记录，避免沿用旧known")
            try check((periodic.latest("primary")?.usedPercent == nil) == primaryUnknown,
                      "primary未知不能转0或借secondary数值")
            try check((periodic.latest("secondary")?.usedPercent == nil) == secondaryUnknown,
                      "secondary未知不能转0或借primary数值")
            if primaryUnknown { try check(periodic.latest("primary")?.resetAt == nil, "未知primary不得借用重置时间") }
            if secondaryUnknown { try check(periodic.latest("secondary")?.resetAt == nil, "未知secondary不得借用重置时间") }
        }
        print("✓ 0%、100%、null和缺窗保持独立，未知窗口不变0，也不借用重置时间")

        let legacy = try rig("legacy")
        try legacy.control("legacy", used: 17)
        legacy.collector.refreshNow()
        try await waitUntil("兼容旧单桶结果") { legacy.records.count == 1 }
        try check(legacy.latest("primary")?.usedPercent == 17, "没有桶映射时允许官方legacy单桶形状")
        print("✓ 兼容无limitId的legacy单桶响应")

        for mode in ["initializeError", "unauth", "error", "malformed", "otherOnly", "mapOtherLegacyCodex", "codexIdOther", "invalidPercent"] {
            let failed = try rig("failure-\(mode)")
            try await failed.seed()
            let successfulAt = failed.collector.lastSuccessAt
            let beforeReads = try failed.readCount()
            try failed.control(mode)
            failed.collector.refreshNow()
            try await waitUntil("拒绝错误响应\(mode)") { !failed.collector.isBusy }
            try check(failed.records.count == 1 && failed.collector.lastSuccessAt == successfulAt,
                      "\(mode)失败不得更新成功记录时间")
            try check((failed.collector.lastAttemptAt ?? .distantPast) > (successfulAt ?? .distantFuture),
                      "\(mode)必须区分尝试时间与成功时间")
            if mode == "initializeError" {
                try check(try failed.readCount() == beforeReads, "初始化失败不得继续请求额度")
            }
            if mode == "unauth" {
                try check(failed.collector.needsLogin && !failed.collector.isRunning, "认证失败必须提示重新登录并停止循环")
            }
            failed.collector.pause()
        }
        print("✓ 初始化、认证、RPC、格式、无Codex桶和越界值失败均保留成功时间")

        let rejected = try rig("store-reject")
        try await rejected.seed()
        let savedDate = rejected.collector.lastSuccessAt
        rejected.rejectSnapshot = true
        rejected.collector.refreshNow()
        try await waitUntil("合成存储拒绝") { !rejected.collector.isBusy }
        try check(rejected.records.count == 1 && rejected.collector.lastSuccessAt == savedDate,
                  "存储失败不得报告新成功时间")
        rejected.collector.pause()
        print("✓ 本地存储拒绝后不报告成功")

        let paused = try rig("pause-late")
        try await paused.seed()
        let beforePauseDate = paused.collector.lastSuccessAt
        try paused.control("lateAfterPause", used: 99, delay: 500)
        let beforePausedReads = try paused.readCount()
        paused.collector.refreshNow()
        for _ in 0..<20 { paused.collector.refreshNow() }
        try await waitUntil("迟到响应已发起") { try paused.readCount() == beforePausedReads + 1 }
        paused.collector.pause()
        try await Task.sleep(for: .seconds(1))
        try check(paused.records.count == 1 && paused.collector.lastSuccessAt == beforePauseDate,
                  "pause后的迟到响应不得写入或更新成功时间")
        try check(try paused.readCount() == beforePausedReads + 1, "连续手动刷新不得重入")
        try check(try paused.events("terminationIgnored").count == 1 && paused.events("readDelivered").count == 2,
                  "合成进程必须在pause后实际尝试送回迟到响应")
        print("✓ 连点不重入，暂停隔离迟到响应")

        let timed = try rig("timeout")
        try await timed.seed()
        let beforeTimeoutDate = timed.collector.lastSuccessAt
        try timed.control("slow", delay: 20_000)
        let beforeTimedReads = try timed.readCount()
        let timeoutStarted = Date()
        timed.collector.refreshNow()
        for _ in 0..<20 { timed.collector.refreshNow() }
        try await waitUntil("15秒超时", timeout: 18) { !timed.collector.isBusy }
        try check(Date().timeIntervalSince(timeoutStarted) >= 14.7, "超时测试必须实际等待本轮超时")
        try check(timed.records.count == 1 && timed.collector.lastSuccessAt == beforeTimeoutDate,
                  "超时不得刷新成功记录")
        try check(try timed.readCount() == beforeTimedReads + 1, "超时等待期间不得并发重入")
        timed.collector.pause()
        print("✓ 实际15秒超时保留旧记录，等待期间无重入")

        let limited = try rig("backoff")
        try await limited.seed()
        let beforeLimitedDate = limited.collector.lastSuccessAt
        try limited.control("rateLimited")
        limited.collector.start()
        try await waitUntil("429退避") { !limited.collector.isBusy && limited.collector.nextRefreshAt != nil }
        let readsAtLimit = try limited.readCount()
        try check((limited.collector.nextRefreshAt?.timeIntervalSinceNow ?? 0) >= 28,
                  "429必须至少约30秒退避")
        for _ in 0..<10 { limited.collector.refreshNow() }
        try await Task.sleep(for: .seconds(6))
        try check(try limited.readCount() == readsAtLimit, "手动刷新和自动周期均不得绕过429退避")
        try check(limited.collector.lastSuccessAt == beforeLimitedDate && limited.records.count == 1,
                  "限流不得刷新成功记录")
        limited.collector.pause()
        print("✓ 429执行至少30秒退避，手动操作和正常周期不能绕过")

        let sleeper = try rig("simulated-sleep")
        sleeper.collector.start()
        try await waitUntil("休眠前采样") { sleeper.records.count == 1 }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let sleepReads = try sleeper.readCount()
        try check(sleeper.collector.isSuspended, "休眠通知必须进入挂起状态")
        try await Task.sleep(for: .seconds(6))
        try check(try sleeper.readCount() == sleepReads, "挂起期间不得继续发起读取")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil("唤醒单次恢复") { sleeper.records.count == 2 }
        try await Task.sleep(for: .milliseconds(250))
        try check(try sleeper.readCount() == sleepReads + 1, "重复唤醒不能补发积压请求")
        sleeper.collector.pause()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        try check(try sleeper.readCount() == sleepReads + 1 && !sleeper.collector.isRunning,
                  "暂停后休眠唤醒不得自行启动")
        print("✓ 模拟休眠通知停止读取，重复唤醒只恢复一次，暂停不被唤醒撤销")

        for fixture in rigs {
            try check(try fixture.events("protocolViolation").isEmpty, "所有合成进程均须遵守初始化顺序且无并发RPC")
        }
        rigs.forEach { $0.collector.pause() }
        try await Task.sleep(for: .milliseconds(200))
    }
}
