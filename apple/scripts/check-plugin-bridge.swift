// Synthetic file-queue and model-boundary checks. No collector or real user store.
import AppKit
import Foundation
import Darwin
import QuotaCore

private struct BridgeCheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw BridgeCheckFailure(description: message) }
}

@MainActor
private final class BridgeRig {
    let root: URL
    let directory: URL
    let bridge: StandalonePluginBridge
    var requests: URL { directory.appendingPathComponent("requests") }
    var responses: URL { directory.appendingPathComponent("responses") }
    init(root: URL, name: String, handler: @escaping (StandalonePluginRequest.Command) throws -> [String: Any]) throws {
        self.root = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = self.root.appendingPathComponent("PluginBridge")
        bridge = StandalonePluginBridge(directory: directory, handler: handler)
        try bridge.openQueue()
    }
    func body(id: String, action: String = "get_status", arguments: [String: Any] = [:], now: Date = Date()) -> [String: Any] {
        ["schemaVersion": 1, "id": id, "createdAt": QuotaDate.string(now), "action": action, "arguments": arguments]
    }
    func write(_ data: Data, id: String, mode: Int = 0o600) throws {
        let file = requests.appendingPathComponent(id + ".json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
    func send(_ value: [String: Any], id: String, now: Date = Date(), mode: Int = 0o600) throws -> [String: Any] {
        try write(JSONSerialization.data(withJSONObject: value), id: id, mode: mode)
        bridge.drain(now: now)
        return try response(id)
    }
    func response(_ id: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: responses.appendingPathComponent(id + ".json"))) as? [String: Any] else {
            throw BridgeCheckFailure(description: "响应不是JSON对象")
        }
        return value
    }
}

@main
struct PluginBridgeCheck {
    @MainActor static func main() {
        do {
            let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("yuliang-plugin-check-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            try queueTests(root)
            try modelTests(root)
            print("PASS plugin bridge: 16 boundary groups; synthetic files/model only, no platform collection or authentication access.")
        } catch {
            fputs("Plugin bridge verification failed: \(error)\n", stderr)
            exit(1)
        }
    }
    @MainActor static func queueTests(_ root: URL) throws {
        var calls = 0
        let rig = try BridgeRig(root: root, name: "queue") { _ in calls += 1; return ["synthetic": true] }
        defer { rig.bridge.stop() }
        for directory in [rig.directory, rig.requests, rig.responses] {
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            try require(permissions?.intValue == 0o700, "桥目录权限必须700")
        }
        let now = Date()
        func id() -> String { UUID().uuidString.lowercased() }
        func errorCode(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
        // 1. Valid queued command and response permissions; a later poll sees a new entry.
        let first = id()
        let result = try rig.send(rig.body(id: first, now: now), id: first, now: now)
        try require(result["ok"] as? Bool == true && calls == 1, "有效请求须执行一次")
        let attributes = try FileManager.default.attributesOfItem(atPath: rig.responses.appendingPathComponent(first + ".json").path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "响应权限必须600")
        let later = id()
        _ = try rig.send(rig.body(id: later, now: now), id: later, now: now)
        try require(calls == 2, "后续轮询不能因目录offset丢请求")
        // 2. Already completed id does not trigger a repeated operation, including after client cleanup.
        _ = try rig.send(rig.body(id: first, now: now), id: first, now: now)
        try FileManager.default.removeItem(at: rig.responses.appendingPathComponent(first + ".json"))
        try require(errorCode(rig.send(rig.body(id: first, now: now), id: first, now: now)) == "duplicate_request", "重复id应拒绝")
        try require(calls == 2, "重复id不能再次触发动作")
        // 3. TTL and future-skew bounds.
        for offset in [-31.0, 6.0] {
            let value = id()
            try require(errorCode(rig.send(rig.body(id: value, now: now.addingTimeInterval(offset)), id: value, now: now)) == "expired_request", "过期或未来请求必须拒绝")
        }
        // 4. Strict schema, exact id binding and no arbitrary keys.
        let malformed: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schemaVersion"] = 2 }), ("bool-version", { $0["schemaVersion"] = true }),
            ("unknown-field", { $0["path"] = "/never/read/auth.json" }),
            ("uuid-mismatch", { $0["id"] = UUID().uuidString }),
            ("unknown-action", { $0["action"] = "run_shell" }),
            ("missing-arguments", { $0.removeValue(forKey: "arguments") })
        ]
        for (_, change) in malformed {
            let value = id(); var body = rig.body(id: value, now: now); change(&body)
            try require(errorCode(rig.send(body, id: value, now: now)) == "invalid_request", "无效schema不能进入handler")
        }
        // 5. Every argument uses exact enum values, types and keys.
        let badArguments: [(String, [String: Any])] = [
            ("get_status", ["path": "secret"]), ("refresh", ["provider": "chatgpt"]),
            ("refresh", ["provider": 1]), ("play_action", ["action": "idle"]),
            ("play_action", ["action": "exec"]), ("select_character", ["character": "../auth"]),
            ("set_display", [:]), ("set_display", ["layout": "full"]),
            ("set_display", ["appearance": "opaque"]), ("set_display", ["language": "zhHans"]),
            ("set_display", ["layout": "compact", "path": "secret"])
        ]
        for (action, arguments) in badArguments {
            let value = id()
            try require(errorCode(rig.send(rig.body(id: value, action: action, arguments: arguments, now: now), id: value, now: now)) == "invalid_arguments", "无效参数必须拒绝")
        }
        // 6. Exact bounded reads and malformed JSON.
        let large = id(); try rig.write(Data(repeating: 32, count: 16_385), id: large); rig.bridge.drain(now: now)
        try require(errorCode(rig.response(large)) == "request_too_large", "16KiB以上必须拒绝")
        let corrupt = id(); try rig.write(Data("{".utf8), id: corrupt); rig.bridge.drain(now: now)
        try require(errorCode(rig.response(corrupt)) == "invalid_request", "无效JSON必须拒绝")
        // 7. Non-private file permissions are rejected rather than read.
        let publicFile = id()
        try require(errorCode(rig.send(rig.body(id: publicFile, now: now), id: publicFile, now: now, mode: 0o644)) == "unsafe_file", "公开可读请求必须拒绝")
        // 8. Neither symlinks, hard links, directories nor pipes are followed/read.
        let target = root.appendingPathComponent("private-sentinel")
        let sentinel = Data("sentinel-credential-never-return".utf8)
        try sentinel.write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = id(); try FileManager.default.createSymbolicLink(at: rig.requests.appendingPathComponent(link + ".json"), withDestinationURL: target)
        let hard = id(); try FileManager.default.linkItem(at: target, to: rig.requests.appendingPathComponent(hard + ".json"))
        let folder = id(); try FileManager.default.createDirectory(at: rig.requests.appendingPathComponent(folder + ".json"), withIntermediateDirectories: false)
        let pipe = id(); try require(mkfifo(rig.requests.appendingPathComponent(pipe + ".json").path, 0o600) == 0, "创建测试pipe失败")
        rig.bridge.drain(now: now)
        for value in [link, hard, folder, pipe] { try require(errorCode(rig.response(value)) == "unsafe_file", "特殊文件必须拒绝") }
        try require(Data(contentsOf: target) == sentinel, "原目标文件必须保持不变")
        // 9. Unknown filenames have no filesystem or handler effect.
        let unknown = rig.requests.appendingPathComponent("not-a-uuid.json")
        try Data("{}".utf8).write(to: unknown); rig.bridge.drain(now: now)
        try require(FileManager.default.fileExists(atPath: unknown.path), "非协议文件不能被当指令删除")
        // 10. A response symlink prevents execution without overwriting its target.
        let poisoned = id()
        try FileManager.default.createSymbolicLink(at: rig.responses.appendingPathComponent(poisoned + ".json"), withDestinationURL: target)
        try rig.write(JSONSerialization.data(withJSONObject: rig.body(id: poisoned, now: now)), id: poisoned)
        rig.bridge.drain(now: now)
        try require(Data(contentsOf: target) == sentinel && calls == 2, "响应符号链接不得触发handler或改目标")
        // 11. A symlink at any bridge-directory boundary is rejected.
        let unsafeParent = root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: unsafeParent, withDestinationURL: rig.root)
        let bad = StandalonePluginBridge(directory: unsafeParent.appendingPathComponent("PluginBridge")) { _ in [:] }
        do { try bad.openQueue(); bad.stop(); throw BridgeCheckFailure(description: "符号链接父目录应拒绝") }
        catch is StandalonePluginFailure {}
        let unsafeRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: unsafeRoot, withDestinationURL: rig.directory)
        let badRoot = StandalonePluginBridge(directory: unsafeRoot) { _ in [:] }
        do { try badRoot.openQueue(); badRoot.stop(); throw BridgeCheckFailure(description: "符号链接桥目录应拒绝") }
        catch is StandalonePluginFailure {}
        // 12. Stale response retention and stop release only this bridge.
        let expired = id(); let old = rig.responses.appendingPathComponent(expired + ".json")
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-180)], ofItemAtPath: old.path)
        rig.bridge.drain(now: now)
        try require(!FileManager.default.fileExists(atPath: old.path), "过期响应应清理")
        rig.bridge.stop(); try require(!rig.bridge.isRunning, "stop必须注销桥")
    }
    @MainActor static func modelTests(_ root: URL) throws {
        let store = StandaloneQuotaStore(directory: root.appendingPathComponent("model-store"))
        let model = StandaloneModel(store: store)
        let now = Date(); let observed = now.addingTimeInterval(-60)
        let secret = "private-org@example.invalid /Users/private-id raw-error-cookie"
        try model.shellTestReceiveSnapshot(SnapshotEnvelope(providerId: .codex, pageKind: "rate-limits", observedAt: observed,
            source: "codex-app-server", windows: [QuotaWindow(id: "primary", label: secret, usedPercent: 21,
                resetAt: now.addingTimeInterval(3600), note: secret, observedAt: observed)], id: "private-org"), now: now)
        model.error = secret
        model.collector.shellTestSetTokenUsage(TokenUsageSnapshot(todayTokens: nil, serverDayTokens: 9_007_199_254_740_993,
            serverDay: "2026-11-04", lifetimeTokens: 9_007_199_254_740_994, peakDailyTokens: nil,
            currentStreakDays: nil, longestStreakDays: nil, longestRunningTurnSec: nil, observedAt: observed, sourceLabel: secret))
        // 13. Whitelist projection strips all identity/error/note/source data; integer strings remain exact.
        let status = try model.handlePluginCommand(.getStatus)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self)
        for forbidden in ["private-org", "example.invalid", "/Users", "raw-error", "cookie", "sourceLabel", "note", "label"] {
            try require(!encoded.contains(forbidden), "去敏状态不得包含私有字段")
        }
        let usage = status["tokenUsage"] as? [String: Any]
        try require(usage?["serverDayTokens"] as? String == "9007199254740993", "Token数字字符串不能丢Int64精度")
        try require(usage?["todayTokens"] is NSNull, "服务端日不得冒称今天")
        let quotas = status["quotas"] as? [[String: Any]]
        let codex = quotas?.first { $0["provider"] as? String == "codex" }
        let windows = codex?["windows"] as? [[String: Any]]
        try require(windows?.first?["remainingPercent"] as? Double == 79, "额度真实79%应保留")
        try require(windows?.last?["remainingPercent"] is NSNull && windows?.last?["observedAt"] is NSNull, "未知窗口保持未知")
        // 14. Every current character and its signature uses actual model selection/play; retired characters rejected.
        for character in model.availableCharacters {
            _ = try model.handlePluginCommand(.selectCharacter(character.rawValue))
            let action = try model.handlePluginCommand(.play("signature"))
            try require(model.document.preferences.character == character && action["played"] as? String == character.signatureAction.rawValue, "角色必须使用专属动作")
        }
        do { _ = try model.handlePluginCommand(.selectCharacter("mochiCat")); throw BridgeCheckFailure(description: "移除角色应拒绝") }
        catch let failure as StandalonePluginFailure { try require(failure.code == "unknown_character", "角色错误必须安全") }
        // 15. Display/language changes, show callback and async-refresh boundary share actual existing hooks.
        for layout in ["standard", "compact", "duo"] {
            _ = try model.handlePluginCommand(.setDisplay(layout: layout, appearance: "light", language: "zh-Hans"))
            try require(model.displayStyle == (layout == "duo" ? .duo : .card), "layout映射必须正确")
            if layout != "duo" { try require(model.compact == (layout == "compact"), "compact必须显著独立") }
        }
        for language in ["system", "en", "ja", "zh-Hans"] {
            let result = try model.handlePluginCommand(.setDisplay(layout: nil, appearance: "dark", language: language))
            try require((result["display"] as? [String: Any])?["language"] as? String == language, "协议语言映射不能泄漏zhHans")
        }
        var shown = false; model.onShowDesktop = { shown = true }
        _ = try model.handlePluginCommand(.showWidget)
        try require(shown && model.desktopVisible, "展示须调用现有窗口hook")
        let before = try model.handlePluginCommand(.getStatus)
        for provider in ["selected", "codex", "claude"] {
            do { _ = try model.handlePluginCommand(.refresh(provider)); throw BridgeCheckFailure(description: "隔离测试不得启动真实采集") }
            catch let failure as StandalonePluginFailure { try require(failure.code == "unavailable", "隔离refresh错误须去敏") }
        }
        let after = try model.handlePluginCommand(.getStatus)
        try require(try JSONSerialization.data(withJSONObject: before["quotas"]!, options: .sortedKeys) == JSONSerialization.data(withJSONObject: after["quotas"]!, options: .sortedKeys), "refresh不能伪造额度或时间")
        // 16. QUOTA_SHELL_TESTING leaves both real collectors stopped and their 60s periods unchanged.
        try require(!model.collector.isRunning && !model.collector.isBusy && !model.claudeCollector.isRunning && !model.claudeCollector.isBusy,
                    "桥测试不得启动真实采集")
        try require(model.collector.interval == 60 && model.claudeCollector.interval == 60, "不能改变60秒采集周期")
    }
}
