import Foundation
import Combine
import AppKit
import Darwin
import CoreFoundation
import QuotaCore

/// Reads only the official local Codex app-server quota and account token-usage methods.
/// No auth files, environment keys, cookies, account identity or model/thread requests are read.
@MainActor
final class CodexQuotaCollector: NSObject, ObservableObject {
    let service: QuotaProvider = .codex
    let interval: TimeInterval = 60
    let isFixture: Bool
    var onSnapshot: ((SnapshotEnvelope) throws -> Void)?

    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var tokenUsageState: TokenUsageReadingState = .unknown
    @Published private(set) var tokenUsageStatus = "等待读取 Token 用量"
    @Published private(set) var tokenUsageLastAttemptAt: Date?
    @Published private(set) var tokenUsageLastSuccessAt: Date?

    @Published private(set) var status = "准备连接本机 Codex"
    /// The quota endpoint's last unresolved failure. Token failures stay separate.
    /// A retry attempt or pause does not hide this; only a saved quota clears it.
    @Published private(set) var quotaError: String?
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var lastSuccessAt: Date?
    @Published private(set) var nextRefreshAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var needsLogin = false
    @Published private(set) var isSuspended = false

    private let fixtureCommand: URL?
    private let fixtureArguments: [String]
    private var session: CodexRateLimitSession?
    private var nextTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cycle: UInt64 = 0
    private var consecutiveFailures = 0
    private var throttleUntil: Date?
    private var resumeAfterSleep = false

    convenience override init() {
        self.init(fixtureCommand: nil, arguments: [])
    }

    #if QUOTA_COLLECTOR_TESTING
    /// Available only in the isolated test build; never shipped in the production app.
    convenience init(fixtureCommand: URL, arguments: [String] = [],
                     onSnapshot: ((SnapshotEnvelope) throws -> Void)? = nil) {
        precondition(fixtureCommand.isFileURL)
        self.init(fixtureCommand: Optional(fixtureCommand), arguments: arguments)
        self.onSnapshot = onSnapshot
    }
    #endif

    private init(fixtureCommand: URL?, arguments: [String]) {
        self.fixtureCommand = fixtureCommand
        fixtureArguments = arguments
        isFixture = fixtureCommand != nil
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep(_:)),
                                                        name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)),
                                                        name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Re-check the existing Codex login and read once. No login flow is started or changed.
    func connect() {
        stopWork()
        isRunning = false
        resumeAfterSleep = false
        refreshNow()
    }

    func start() {
        guard canStart() else { return }
        isRunning = true
        needsLogin = false
        if isSuspended {
            resumeAfterSleep = true
            status = "电脑休眠中，唤醒后继续读取 Codex"
            return
        }
        if let throttleUntil, throttleUntil > Date() {
            schedule(after: throttleUntil.timeIntervalSinceNow, message: "Codex 要求等待，退避结束后继续读取")
        } else {
            beginAttempt()
        }
    }

    func pause() {
        stopWork()
        isRunning = false
        resumeAfterSleep = false
        status = "已暂停，保留上次成功记录"
    }

    func refreshNow() {
        guard !isBusy else { return }
        guard !isSuspended else { status = "电脑休眠中，暂不发起读取"; return }
        guard canStart() else { return }
        if let throttleUntil, throttleUntil > Date() {
            status = "Codex 正在限流，请等待退避结束"
            return
        }
        beginAttempt()
    }

    private func canStart() -> Bool {
        guard onSnapshot != nil else {
            status = "尚未连接本机额度存储"
            quotaError = status
            return false
        }
        guard executableURL() != nil else {
            status = "未找到本机 Codex，请先安装并登录 Codex"
            quotaError = status
            return false
        }
        return true
    }

    private func executableURL() -> URL? {
        if let fixtureCommand { return FileManager.default.isExecutableFile(atPath: fixtureCommand.path) ? fixtureCommand : nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".npm-global/bin/codex").path
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func beginAttempt() {
        guard !isBusy, !isSuspended, let executable = executableURL() else { return }
        nextTask?.cancel(); nextTask = nil
        nextRefreshAt = nil
        cycle &+= 1
        let expectedCycle = cycle
        isBusy = true
        needsLogin = false
        lastAttemptAt = Date()
        tokenUsageLastAttemptAt = lastAttemptAt
        status = isFixture ? "正在读取 Codex 合成测试记录" : "正在读取本机 Codex 额度"
        let arguments = isFixture ? fixtureArguments : ["app-server", "--listen", "stdio://"]
        let worker = CodexRateLimitSession(executable: executable, arguments: arguments)
        session = worker
        worker.start { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.cycle == expectedCycle, self.isBusy else { return }
                self.received(result)
            }
        }
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.cycle == expectedCycle, self.isBusy else { return }
            self.session?.timeOut()
        }
    }

    private func received(_ batch: CodexReadBatch) {
        // Each endpoint has its own success/failure and timestamp. A missing or
        // unsupported token method never invalidates an otherwise valid quota.
        receiveTokenUsage(batch.tokenUsage)
        switch batch.quota {
        case .success(let sample):
            let snapshot: SnapshotEnvelope
            do {
                snapshot = try Self.snapshot(from: sample.data, now: sample.observedAt)
            } catch CodexRPCFailure.missingCodexBucket {
                failAttempt("Codex 未返回对应额度，保留上次记录")
                return
            } catch {
                failAttempt("Codex 额度字段无法验证，保留上次记录")
                return
            }
            do {
                guard let onSnapshot else { throw CodexRPCFailure.protocolFailure }
                try onSnapshot(snapshot)
                lastSuccessAt = snapshot.observedAt
                quotaError = nil
                consecutiveFailures = 0
                if case .failure(.rateLimited) = batch.tokenUsage {
                    throttleUntil = Date().addingTimeInterval(interval)
                } else { throttleUntil = nil }
                finishAttempt()
                if isRunning {
                    let elapsed = Date().timeIntervalSince(lastAttemptAt ?? Date())
                    let regularDelay = max(0.2, interval - elapsed)
                    let delay = max(regularDelay, throttleUntil?.timeIntervalSinceNow ?? 0)
                    schedule(after: delay, message: "已读取 Codex · 目标每 \(Int(interval)) 秒刷新")
                } else { status = "已完成一次 Codex 额度读取" }
            } catch {
                failAttempt("本机额度保存失败，保留上次成功记录")
            }
        case .failure(let error):
            switch error {
            case .loginRequired:
                stopWork()
                isRunning = false
                resumeAfterSleep = false
                needsLogin = true
                status = "请先在 Codex 中登录账户，再重新连接"
                quotaError = status
            case .unsupported:
                stopWork()
                isRunning = false
                resumeAfterSleep = false
                status = "本机 Codex 暂不支持额度读取，请检查版本"
                quotaError = status
            case .rateLimited:
                failAttempt("Codex 暂时限流，刷新间隔已延长", retryAfter: 60)
            case .launchFailed:
                failAttempt("本机 Codex 未能启动，保留上次记录")
            case .oversized, .protocolFailure, .missingCodexBucket:
                failAttempt("Codex 返回记录无法验证，保留上次记录")
            case .unavailable:
                failAttempt("Codex 暂时无法读取，保留上次记录")
            }
        }
    }

    private func receiveTokenUsage(_ result: Result<CodexRPCSample, CodexRPCFailure>) {
        switch result {
        case .success(let sample):
            do {
                let value = try TokenUsageSnapshot.decode(sample.data, observedAt: sample.observedAt)
                tokenUsage = value
                tokenUsageLastSuccessAt = value.observedAt
                tokenUsageState = .available
                tokenUsageStatus = value.lifetimeTokens == nil && value.serverDayTokens == nil
                    ? "服务端暂未返回 Token 数值" : "已读取账号 Token 用量"
            } catch {
                tokenUsageState = .invalid
                tokenUsageStatus = "Token 字段无法验证，保留上次记录"
            }
        case .failure(let failure):
            switch failure {
            case .unsupported:
                tokenUsageState = .unsupported
                tokenUsageStatus = "本机 Codex 暂不支持 Token 用量读取"
            case .loginRequired:
                tokenUsageState = .loginRequired
                tokenUsageStatus = "Token 用量需要 Codex 账号登录"
            case .rateLimited:
                tokenUsageState = .rateLimited
                tokenUsageStatus = "Token 用量暂时限流，保留上次记录"
            case .protocolFailure, .oversized, .missingCodexBucket:
                tokenUsageState = .invalid
                tokenUsageStatus = "Token 字段无法验证，保留上次记录"
            case .launchFailed, .unavailable:
                tokenUsageState = .unavailable
                tokenUsageStatus = "Token 用量暂时不可读，保留上次记录"
            }
        }
    }

    #if QUOTA_SHELL_TESTING
    /// Synthetic UI checks only. This entry point is absent from production.
    func shellTestSetTokenUsage(_ snapshot: TokenUsageSnapshot) {
        precondition(!isRunning && !isBusy && lastAttemptAt == nil)
        tokenUsage = snapshot
        tokenUsageState = .available
        tokenUsageLastSuccessAt = snapshot.observedAt
        tokenUsageStatus = "合成 UI 测试数据"
    }

    /// Exercises the real quota decoding/acceptance/error path with explicit
    /// fixture data. Nil simulates an unavailable quota endpoint; no CLI starts.
    func shellTestReceiveQuota(_ data: Data?, observedAt: Date) {
        precondition(!isRunning && !isBusy && lastAttemptAt == nil)
        let quota: Result<CodexRPCSample, CodexRPCFailure> = data.map {
            .success(.init(data: $0, observedAt: observedAt))
        } ?? .failure(.unavailable)
        received(.init(quota: quota, tokenUsage: .failure(.unsupported)))
    }
    #endif

    private func finishAttempt() {
        timeoutTask?.cancel(); timeoutTask = nil
        session?.cancel(); session = nil
        isBusy = false
    }

    private func stopWork() {
        cycle &+= 1
        nextTask?.cancel(); nextTask = nil
        nextRefreshAt = nil
        finishAttempt()
    }

    private func failAttempt(_ message: String, retryAfter: TimeInterval? = nil) {
        quotaError = message
        finishAttempt()
        consecutiveFailures = min(7, consecutiveFailures + 1)
        let delay = retryAfter ?? min(300, interval * pow(2, Double(consecutiveFailures - 1)))
        if retryAfter != nil { throttleUntil = Date().addingTimeInterval(delay) }
        if isRunning {
            schedule(after: delay, message: "\(message) · \(Int(ceil(delay))) 秒后重试")
        } else { status = message }
    }

    private func schedule(after delay: TimeInterval, message: String) {
        nextTask?.cancel()
        let safeDelay = max(0.2, delay)
        let expectedCycle = cycle
        nextRefreshAt = Date().addingTimeInterval(safeDelay)
        status = message
        nextTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(safeDelay))
            guard !Task.isCancelled, let self, self.isRunning, self.cycle == expectedCycle else { return }
            self.beginAttempt()
        }
    }

    @objc private func willSleep(_ notification: Notification) {
        resumeAfterSleep = isRunning
        isSuspended = true
        stopWork()
        if isRunning { status = "电脑休眠中，唤醒后继续读取 Codex" }
    }

    @objc private func didWake(_ notification: Notification) {
        guard isSuspended else { return }
        isSuspended = false
        let shouldResume = resumeAfterSleep && isRunning
        resumeAfterSleep = false
        guard shouldResume else { return }
        guard canStart() else { isRunning = false; return }
        if let throttleUntil, throttleUntil > Date() {
            schedule(after: throttleUntil.timeIntervalSinceNow, message: "Codex 要求等待，退避结束后继续读取")
        } else { beginAttempt() }
    }

    /// Select only Codex's bucket, never another product's limits or credit balance.
    private static func snapshot(from data: Data, now: Date) throws -> SnapshotEnvelope {
        guard data.count <= 100_000,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexRPCFailure.protocolFailure
        }
        let bucket: [String: Any]
        if let rawBuckets = result["rateLimitsByLimitId"], !(rawBuckets is NSNull) {
            guard let buckets = rawBuckets as? [String: Any], let codex = buckets["codex"] else {
                throw CodexRPCFailure.missingCodexBucket
            }
            if codex is NSNull { bucket = [:] }
            else if let value = codex as? [String: Any] { bucket = value }
            else { throw CodexRPCFailure.protocolFailure }
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            let id = legacy["limitId"]
            guard id == nil || id is NSNull || (id as? String) == "codex" else { throw CodexRPCFailure.missingCodexBucket }
            bucket = legacy
        } else {
            throw CodexRPCFailure.missingCodexBucket
        }
        let selectedID = bucket["limitId"]
        guard selectedID == nil || selectedID is NSNull || (selectedID as? String) == "codex" else {
            throw CodexRPCFailure.missingCodexBucket
        }
        let windows = try ["primary", "secondary"].map { id -> QuotaWindow in
            let raw = bucket[id]
            guard raw == nil || raw is NSNull || raw is [String: Any] else { throw CodexRPCFailure.protocolFailure }
            let value = raw as? [String: Any] ?? [:]
            let used = try optionalNumber(value["usedPercent"])
            guard used == nil || (0...100).contains(used!) else { throw CodexRPCFailure.protocolFailure }
            let minutes = try optionalInteger(value["windowDurationMins"])
            guard minutes == nil || minutes! >= 0 else { throw CodexRPCFailure.protocolFailure }
            let reset = try optionalInteger(value["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let label: String
            if let minutes {
                if minutes != 0 && minutes % 1_440 == 0 { label = "\(minutes / 1_440)天额度" }
                else if minutes != 0 && minutes % 60 == 0 { label = "\(minutes / 60)小时额度" }
                else { label = "\(minutes)分钟额度" }
            } else { label = id == "primary" ? "主额度窗口" : "另一额度窗口" }
            return QuotaWindow(id: id, label: label, usedPercent: used, resetAt: reset,
                               note: "来自 Codex 官方本机额度接口；未返回的数值保持未知。", observedAt: now)
        }
        let snapshot = SnapshotEnvelope(providerId: .codex, pageKind: "rate-limits", observedAt: now,
                                        source: "codex-app-server", windows: windows)
        // Round-trip enforces the same strict date/size contract used by durable storage.
        return try SnapshotEnvelope.decode(JSONEncoder().encode(snapshot), now: now)
    }

    private static func optionalNumber(_ raw: Any?) throws -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw CodexRPCFailure.protocolFailure
        }
        return value.doubleValue
    }
    private static func optionalInteger(_ raw: Any?) throws -> Int64? {
        guard let value = try optionalNumber(raw) else { return nil }
        guard let integer = Int64(exactly: value) else { throw CodexRPCFailure.protocolFailure }
        return integer
    }
}

private enum CodexRPCFailure: Error, Equatable, Sendable {
    case loginRequired, unsupported, rateLimited, launchFailed, unavailable, protocolFailure, oversized, missingCodexBucket
}

/// All Process/Pipe state stays on one serial queue. Only bounded JSON data or
/// a sanitized error crosses back to the main actor; stdout/stderr are never logged.
private struct CodexRPCSample: Sendable {
    let data: Data
    let observedAt: Date
}

private struct CodexReadBatch: Sendable {
    let quota: Result<CodexRPCSample, CodexRPCFailure>
    let tokenUsage: Result<CodexRPCSample, CodexRPCFailure>
}

private final class CodexRateLimitSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yuliang.codex-rate-limits")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let executable: URL
    private let arguments: [String]
    private var buffer = Data()
    private var totalBytes = 0
    private var initialized = false
    private var finished = false
    private var quotaResult: Result<CodexRPCSample, CodexRPCFailure>?
    private var completion: (@Sendable (CodexReadBatch) -> Void)?

    init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    func start(completion: @escaping @Sendable (CodexReadBatch) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            self.completion = completion
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            // Preserve the actual user's standard login location without reading
            // inherited API-key variables or passing them into the child process.
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"
            ]
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                self.queue.async { [self] in self.receive(data) }
            }
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in
                    if !self.finished { self.completeFailure(.unavailable) }
                }
            }
            do {
                try process.run()
                try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                    "name": "yuliang_quota", "title": "余量额度小窗", "version": "0.13.0"
                ]]])
            } catch { completeFailure(.launchFailed) }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            completion = nil
            cleanup()
        }
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        guard !data.isEmpty else { completeFailure(.unavailable); return }
        totalBytes += data.count
        guard totalBytes <= 1_000_000 else { completeFailure(.oversized); return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard line.count <= 100_000 else { completeFailure(.oversized); return }
            if line.isEmpty { continue }
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexRPCFailure.protocolFailure }
                // Server notifications are not user data and are not retained.
                guard let id = object["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID() else { continue }
                if id.intValue == 1 && !initialized {
                    if let error = object["error"] as? [String: Any] { completeFailure(classify(error)); return }
                    guard object["result"] is [String: Any] else { throw CodexRPCFailure.protocolFailure }
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id.intValue == 2 && initialized && quotaResult == nil {
                    if let error = object["error"] as? [String: Any] {
                        quotaResult = .failure(classify(error))
                    } else if let result = object["result"] as? [String: Any] {
                        let quota = result.filter { $0.key == "rateLimitsByLimitId" || $0.key == "rateLimits" }
                        let bytes = try JSONSerialization.data(withJSONObject: quota)
                        guard bytes.count <= 100_000 else { throw CodexRPCFailure.oversized }
                        quotaResult = .success(CodexRPCSample(data: bytes, observedAt: Date()))
                    } else {
                        quotaResult = .failure(.protocolFailure)
                    }
                    // One shared 60-second cycle and one initialized process.
                    // No thread id is supplied, and no conversation method is used.
                    try send(["id": 3, "method": "account/usage/read", "params": [:]])
                } else if id.intValue == 3 && initialized && quotaResult != nil {
                    if let error = object["error"] as? [String: Any] { completeFailure(classify(error)); return }
                    guard let result = object["result"] as? [String: Any] else { throw CodexRPCFailure.protocolFailure }
                    // Retain only account summary metrics and date/token buckets.
                    // In particular, discard threadUsage, identity and unknown fields.
                    var usage: [String: Any] = [:]
                    if let raw = result["summary"] {
                        if let summary = raw as? [String: Any] {
                            let fields: Set<String> = ["lifetimeTokens", "peakDailyTokens", "currentStreakDays", "longestStreakDays", "longestRunningTurnSec"]
                            usage["summary"] = summary.filter { fields.contains($0.key) }
                        } else { usage["summary"] = raw }
                    }
                    if let raw = result["dailyUsageBuckets"] {
                        if let buckets = raw as? [[String: Any]] {
                            usage["dailyUsageBuckets"] = buckets.map { $0.filter { $0.key == "startDate" || $0.key == "tokens" } }
                        } else { usage["dailyUsageBuckets"] = raw }
                    }
                    let bytes = try JSONSerialization.data(withJSONObject: usage)
                    guard bytes.count <= 100_000 else { throw CodexRPCFailure.oversized }
                    complete(CodexReadBatch(quota: quotaResult!, tokenUsage: .success(CodexRPCSample(data: bytes, observedAt: Date()))))
                    return
                }
            } catch let error as CodexRPCFailure { completeFailure(error); return }
            catch { completeFailure(.protocolFailure); return }
            if finished { return }
        }
        if buffer.count > 100_000 { completeFailure(.oversized) }
    }

    private func send(_ object: [String: Any]) throws {
        guard process.isRunning else { throw CodexRPCFailure.unavailable }
        var bytes = try JSONSerialization.data(withJSONObject: object)
        guard bytes.count <= 10_000 else { throw CodexRPCFailure.oversized }
        bytes.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    private func classify(_ error: [String: Any]) -> CodexRPCFailure {
        let code = (error["code"] as? NSNumber)?.intValue
        let message = (error["message"] as? String ?? "").lowercased()
        if code == -32601 { return .unsupported }
        if code == 429 || message.contains("429") || message.contains("too many requests") || message.contains("rate limit") { return .rateLimited }
        if code == 401 || message.contains("not logged in") || message.contains("not authenticated")
            || message.contains("unauthorized") || message.contains("login required")
            || message.contains("authentication required") || message.contains("please log in")
            || message.contains("sign in") || message.contains("api key") { return .loginRequired }
        return .unavailable
    }

    func timeOut() {
        queue.async { [self] in completeFailure(.unavailable) }
    }

    private func completeFailure(_ failure: CodexRPCFailure) {
        complete(CodexReadBatch(quota: quotaResult ?? .failure(failure), tokenUsage: .failure(failure)))
    }

    private func complete(_ result: CodexReadBatch) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        cleanup()
        callback?(result)
    }

    private func cleanup() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let child = process
            queue.asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}
