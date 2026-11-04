import AppKit
import Foundation
import CoreFoundation
import Darwin
import QuotaCore

/// This bridge has no socket, network service, authentication reader or collector.
/// Same-user requests enter one bounded private queue; only explicit model operations
/// and allowlisted, identity-free status values can cross the boundary.
struct StandalonePluginFailure: Error {
    let code: String
    let message: String
    static let invalidRequest = Self(code: "invalid_request", message: "The request is invalid.")
    static let invalidArguments = Self(code: "invalid_arguments", message: "The command arguments are invalid.")
    static let unsafeFile = Self(code: "unsafe_file", message: "The queue file does not meet local access requirements.")
    static let internalError = Self(code: "internal_error", message: "The local operation could not be completed.")
}

struct StandalonePluginRequest {
    enum Command {
        case getStatus, refresh(String), showWidget, play(String), selectCharacter(String)
        case setDisplay(layout: String?, appearance: String?, language: String?)
    }
    let id: String
    let command: Command
    static let maximumBytes = 16_384
    static let timeToLive: TimeInterval = 30

    static func identifier(_ value: String) -> Bool {
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    static func decode(_ data: Data, filenameID: String, now: Date) throws -> Self {
        guard data.count <= maximumBytes else {
            throw StandalonePluginFailure(code: "request_too_large", message: "The request exceeds 16 KiB.")
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["schemaVersion", "id", "createdAt", "action", "arguments"],
              let version = value["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let id = value["id"] as? String, identifier(id), id.lowercased() == filenameID.lowercased(),
              let created = value["createdAt"] as? String, let date = try? QuotaDate.parse(created),
              let action = value["action"] as? String,
              let arguments = value["arguments"] as? [String: Any] else { throw StandalonePluginFailure.invalidRequest }
        guard now.timeIntervalSince(date) <= timeToLive, date <= now.addingTimeInterval(5) else {
            throw StandalonePluginFailure(code: "expired_request", message: "The request timestamp is outside the allowed window.")
        }
        func fields(_ allowed: Set<String>) throws {
            guard Set(arguments.keys).isSubset(of: allowed), arguments.values.allSatisfy({ $0 is String }) else {
                throw StandalonePluginFailure.invalidArguments
            }
        }
        let command: Command
        switch action {
        case "get_status": try fields([]); command = .getStatus
        case "show_widget": try fields([]); command = .showWidget
        case "refresh":
            try fields(["provider"])
            let provider = arguments["provider"] as? String ?? "selected"
            guard ["selected", "codex", "claude"].contains(provider) else { throw StandalonePluginFailure.invalidArguments }
            command = .refresh(provider)
        case "play_action":
            try fields(["action"])
            guard let action = arguments["action"] as? String,
                  ["signature", "random"].contains(action) || BuddyAction.interactiveActions.contains(where: { $0.rawValue == action }) else {
                throw StandalonePluginFailure.invalidArguments
            }
            command = .play(action)
        case "select_character":
            try fields(["character"])
            guard let character = arguments["character"] as? String,
                  QuotaCharacter(rawValue: character) != nil else { throw StandalonePluginFailure.invalidArguments }
            command = .selectCharacter(character)
        case "set_display":
            try fields(["layout", "appearance", "language"])
            guard !arguments.isEmpty else { throw StandalonePluginFailure.invalidArguments }
            let layout = arguments["layout"] as? String
            let appearance = arguments["appearance"] as? String
            let language = arguments["language"] as? String
            guard layout.map({ ["standard", "compact", "duo"].contains($0) }) ?? true,
                  appearance.map({ ["system", "light", "dark"].contains($0) }) ?? true,
                  language.map({ ["system", "zh-Hans", "en", "ja"].contains($0) }) ?? true else {
                throw StandalonePluginFailure.invalidArguments
            }
            command = .setDisplay(layout: layout, appearance: appearance, language: language)
        default: throw StandalonePluginFailure.invalidRequest
        }
        return Self(id: id, command: command)
    }
}

@MainActor
final class StandalonePluginBridge: NSObject {
    let directory: URL
    private let handler: (StandalonePluginRequest.Command) throws -> [String: Any]
    private var requests: Int32 = -1
    private var responses: Int32 = -1
    private var timer: Timer?
    private var completed: [String: Date] = [:]
    private(set) var isRunning = false

    init(directory: URL, handler: @escaping (StandalonePluginRequest.Command) throws -> [String: Any]) {
        self.directory = directory
        self.handler = handler
    }
    convenience init(model: StandaloneModel) {
        self.init(directory: model.store.directory.appendingPathComponent("PluginBridge", isDirectory: true)) { [weak model] command in
            guard let model else { throw StandalonePluginFailure.internalError }
            return try model.handlePluginCommand(command)
        }
    }

    /// Traversal opens every directory component with O_NOFOLLOW. Parent folders
    /// are never chmodded or created; only the dedicated bridge tree is managed.
    private static func openParent(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw StandalonePluginFailure.unsafeFile }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StandalonePluginFailure.unsafeFile }
        for component in url.pathComponents where component != "/" {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { throw StandalonePluginFailure.unsafeFile }
            descriptor = next
        }
        return descriptor
    }
    private static func privateDirectory(_ name: String, parent: Int32) throws -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw StandalonePluginFailure.unsafeFile }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StandalonePluginFailure.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, fchmod(descriptor, 0o700) == 0 else {
            close(descriptor); throw StandalonePluginFailure.unsafeFile
        }
        return descriptor
    }

    /// Tests call openQueue/drain only with an explicit temporary directory.
    /// Production registration is absent from QUOTA_SHELL_TESTING app startup.
    func openQueue() throws {
        guard requests < 0 else { return }
        let parent = try Self.openParent(directory.deletingLastPathComponent())
        defer { close(parent) }
        let bridge = try Self.privateDirectory(directory.lastPathComponent, parent: parent)
        defer { close(bridge) }
        let requestDirectory = try Self.privateDirectory("requests", parent: bridge)
        do { responses = try Self.privateDirectory("responses", parent: bridge) }
        catch { close(requestDirectory); throw error }
        requests = requestDirectory
        isRunning = true
    }
    func start() throws {
        try openQueue()
        guard timer == nil else { return }
        let next = Timer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer = next
        RunLoop.main.add(next, forMode: .common)
        drain()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if requests >= 0 { close(requests); requests = -1 }
        if responses >= 0 { close(responses); responses = -1 }
        completed.removeAll()
        isRunning = false
    }
    @objc private func tick() { drain() }

    private func entries(_ descriptor: Int32, limit: Int = 64) -> [String] {
        // A fresh descriptor has its own directory offset; dup() would retain the
        // exhausted offset between polls and miss later requests.
        let cursor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cursor >= 0, let stream = fdopendir(cursor) else { if cursor >= 0 { close(cursor) }; return [] }
        defer { closedir(stream) }
        var result: [String] = []
        while result.count < limit, let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
    private func regular(_ descriptor: Int32, info: inout stat) -> Bool {
        fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && info.st_uid == geteuid() && info.st_nlink == 1 && info.st_mode & 0o7777 == 0o600
    }
    private func readRequest(_ name: String) throws -> Data {
        let descriptor = openat(requests, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw StandalonePluginFailure.unsafeFile }
        defer { close(descriptor) }
        var before = stat()
        guard regular(descriptor, info: &before) else { throw StandalonePluginFailure.unsafeFile }
        guard before.st_size <= StandalonePluginRequest.maximumBytes else {
            throw StandalonePluginFailure(code: "request_too_large", message: "The request exceeds 16 KiB.")
        }
        var data = Data(count: StandalonePluginRequest.maximumBytes + 1)
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        var after = stat()
        guard count >= 0, regular(descriptor, info: &after), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              count == after.st_size else { throw StandalonePluginFailure.unsafeFile }
        guard count <= StandalonePluginRequest.maximumBytes else {
            throw StandalonePluginFailure(code: "request_too_large", message: "The request exceeds 16 KiB.")
        }
        data.count = count
        return data
    }
    private func hasResponse(_ name: String) -> Bool {
        var info = stat()
        return fstatat(responses, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
    private func writeResponse(_ value: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 131_072 else { throw StandalonePluginFailure.internalError }
        let temporary = ".\(UUID().uuidString).tmp"
        let descriptor = openat(responses, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StandalonePluginFailure.unsafeFile }
        defer { close(descriptor); unlinkat(responses, temporary, 0) }
        guard fchmod(descriptor, 0o600) == 0 else { throw StandalonePluginFailure.unsafeFile }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StandalonePluginFailure.internalError }
                offset += count
            }
        }
        guard !hasResponse(name), renameat(responses, temporary, responses, name) == 0 else {
            throw StandalonePluginFailure.unsafeFile
        }
    }

    func drain(now: Date = Date()) {
        guard requests >= 0, responses >= 0 else { return }
        completed = completed.filter { now.timeIntervalSince($0.value) < 60 }
        for name in entries(requests) where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard StandalonePluginRequest.identifier(id) else { continue }
            // Existing responses and a short in-memory ledger prevent a retry
            // from triggering an already-completed UI action twice.
            if hasResponse(name) { unlinkat(requests, name, 0); continue }
            var envelope: [String: Any] = ["schemaVersion": 1, "id": id, "generatedAt": QuotaDate.string(now)]
            do {
                guard completed[id.lowercased()] == nil else {
                    throw StandalonePluginFailure(code: "duplicate_request", message: "This request was already handled.")
                }
                let request = try StandalonePluginRequest.decode(readRequest(name), filenameID: id, now: now)
                envelope["result"] = try handler(request.command)
                envelope["ok"] = true
            } catch {
                let failure = error as? StandalonePluginFailure ?? .internalError
                envelope["ok"] = false
                envelope["error"] = ["code": failure.code, "message": failure.message]
            }
            do {
                try writeResponse(envelope, name: name)
                completed[id.lowercased()] = now
                unlinkat(requests, name, 0)
            } catch {
                // No raw filesystem error, request data or local path is logged.
                // Leave the request for a later bounded retry if no action ran.
                completed[id.lowercased()] = now
            }
        }
        for name in entries(responses) where name.hasSuffix(".json") {
            guard StandalonePluginRequest.identifier(String(name.dropLast(5))) else { continue }
            var info = stat()
            if fstatat(responses, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
               now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 120 {
                unlinkat(responses, name, 0)
            }
        }
    }
}

extension StandaloneModel {
    private var pluginLayout: String { displayStyle == .duo ? "duo" : compact ? "compact" : "standard" }
    private var pluginLanguage: String { language == .zhHans ? "zh-Hans" : language.rawValue }
    private var pluginDisplay: [String: Any] {
        ["layout": pluginLayout, "appearance": appearance.rawValue, "language": pluginLanguage]
    }
    private func pluginCharacter(_ value: QuotaCharacter) -> [String: Any] {
        ["id": value.rawValue, "name": YuliangL10n.text(value.name),
         "actions": BuddyAction.interactiveActions.map(\.rawValue) + ["signature", "random"],
         "signatureAction": value.signatureAction.rawValue]
    }
    private func pluginStatus(now: Date = Date()) -> [String: Any] {
        let quotas: [[String: Any]] = [QuotaProvider.codex, .claude].map { provider in
            let ids = provider == .codex ? ["primary", "secondary"] : ["session", "weekly", "sonnet-weekly"]
            let record = document.records.first { $0.providerId == provider }
            let windows: [[String: Any]] = ids.map { id in
                let value = QuotaPresentation(document: document, provider: provider, windowId: id, now: now)
                return ["id": id, "remainingPercent": value.remainingPercent.map { $0 as Any } ?? NSNull(),
                        "resetAt": value.resetAt.map { QuotaDate.string($0) as Any } ?? NSNull(),
                        "observedAt": value.observedAt.map { QuotaDate.string($0) as Any } ?? NSNull(),
                        "freshness": value.freshness.rawValue]
            }
            let selected = QuotaPresentation(document: document, provider: provider, now: now).window?.id
            return ["provider": provider.rawValue, "available": record != nil,
                    "selectedWindowId": selected.flatMap { ids.contains($0) ? $0 : nil }.map { $0 as Any } ?? NSNull(),
                    "windows": windows]
        }
        let usage = collector.tokenUsage
        let state: String
        switch collector.tokenUsageState {
        case .unknown: state = "unknown"
        case .available: state = "available"
        case .unsupported: state = "unsupported"
        case .unavailable: state = "unavailable"
        case .loginRequired: state = "loginRequired"
        case .rateLimited: state = "rateLimited"
        case .invalid: state = "invalid"
        }
        let tokens: [String: Any] = ["provider": "codex", "state": state,
            "available": collector.tokenUsageState == .available && (usage?.serverDayTokens != nil || usage?.lifetimeTokens != nil),
            "observedAt": usage.map { QuotaDate.string($0.observedAt) as Any } ?? NSNull(),
            "serverDay": usage?.serverDay.map { $0 as Any } ?? NSNull(),
            "serverDayTokens": usage?.serverDayTokens.map { String($0) as Any } ?? NSNull(),
            "lifetimeTokens": usage?.lifetimeTokens.map { String($0) as Any } ?? NSNull(), "todayTokens": NSNull()]
        return ["selectedProvider": document.preferences.providerId.rawValue, "quotas": quotas, "tokenUsage": tokens,
                "character": pluginCharacter(document.preferences.character),
                "characters": availableCharacters.map(pluginCharacter), "display": pluginDisplay]
    }
    func handlePluginCommand(_ command: StandalonePluginRequest.Command) throws -> [String: Any] {
        switch command {
        case .getStatus: return pluginStatus()
        case .refresh(let requested):
            let provider = requested == "selected" ? document.preferences.providerId.rawValue : requested
            guard ["codex", "claude"].contains(provider) else { throw StandalonePluginFailure.invalidArguments }
            let busy = provider == "claude" ? claudeCollector.isBusy : collector.isBusy
            if busy { return ["status": "busy", "provider": provider, "asynchronous": true] }
            #if QUOTA_SHELL_TESTING
            // The real transport and model boundary are tested without starting
            // either platform collector or inspecting credentials.
            throw StandalonePluginFailure(code: "unavailable", message: "Collection is disabled in the isolated test build.")
            #else
            if provider == "claude" { claudeCollector.refreshNow() } else { collector.refreshNow() }
            let started = provider == "claude" ? claudeCollector.isBusy : collector.isBusy
            guard started else { throw StandalonePluginFailure(code: "unavailable", message: "Refresh is currently unavailable. Use the app to check its connection.") }
            return ["status": "accepted", "provider": provider, "asynchronous": true]
            #endif
        case .showWidget:
            (onPluginShowDesktop ?? onShowDesktop)?()
            desktopVisible = true
            return ["visible": true]
        case .play(let raw):
            guard !isEatingUsage else { throw StandalonePluginFailure(code: "busy", message: "The buddy is finishing a quota reaction.") }
            let action: BuddyAction
            if raw == "signature" { action = document.preferences.character.signatureAction }
            else if raw == "random" { action = document.preferences.character.companionActions.randomElement() ?? .pat }
            else if let value = BuddyAction(rawValue: raw), BuddyAction.interactiveActions.contains(value) { action = value }
            else { throw StandalonePluginFailure.invalidArguments }
            play(action)
            return ["played": action.rawValue, "character": document.preferences.character.rawValue]
        case .selectCharacter(let raw):
            guard let character = QuotaCharacter(rawValue: raw), availableCharacters.contains(character) else {
                throw StandalonePluginFailure(code: "unknown_character", message: "This character is not available in the installed app.")
            }
            selectCharacter(character)
            guard document.preferences.character == character else { throw StandalonePluginFailure.internalError }
            return ["character": pluginCharacter(character)]
        case .setDisplay(let layout, let appearance, let language):
            guard layout.map({ ["standard", "compact", "duo"].contains($0) }) ?? true,
                  appearance.map({ StandaloneAppearance(rawValue: $0) != nil }) ?? true,
                  language.map({ ["system", "zh-Hans", "en", "ja"].contains($0) }) ?? true else {
                throw StandalonePluginFailure.invalidArguments
            }
            let nextLanguage = language.flatMap { $0 == "zh-Hans" ? YuliangLanguage.zhHans : YuliangLanguage(rawValue: $0) }
            let change = {
                if let layout {
                    if layout == "duo" { self.displayStyle = .duo }
                    else { self.compact = layout == "compact"; self.displayStyle = .card }
                }
                if let appearance, let value = StandaloneAppearance(rawValue: appearance) { self.appearance = value }
                if let nextLanguage { self.language = nextLanguage }
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { change() }
            else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.22; change() } }
            return ["display": pluginDisplay]
        }
    }
}
