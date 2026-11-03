import Foundation
import QuotaCore
import Darwin

enum StandaloneStoreError: LocalizedError {
    case corrupt, lockFailed

    var errorDescription: String? {
        switch self {
        case .corrupt: return "本机额度文件无法验证，已保留原文件。"
        case .lockFailed: return "本机额度正在更新，请稍后重试。"
        }
    }
}

/// The Mac desktop window owns ordinary on-device storage. It does not use or
/// silently fall back from the signed WidgetKit app's App Group container.
final class StandaloneQuotaStore: @unchecked Sendable {
    static let shared = StandaloneQuotaStore()
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YuliangStandalone", isDirectory: true)
    }

    private func locked<T>(_ action: (URL) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("store.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StandaloneStoreError.lockFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StandaloneStoreError.lockFailed }
        defer { flock(descriptor, LOCK_UN) }
        return try action(directory.appendingPathComponent("quota.json"))
    }

    private func readUnlocked(_ url: URL, now: Date) throws -> QuotaStoreDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return QuotaStoreDocument() }
        let data = try Data(contentsOf: url)
        do { return try QuotaStoreDocument.decode(data, now: now) }
        catch { throw StandaloneStoreError.corrupt }
    }

    private func writeUnlocked(_ document: QuotaStoreDocument, to url: URL, now: Date) throws {
        let data = try document.encoded(now: now)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read() throws -> QuotaStoreDocument {
        try locked { try readUnlocked($0, now: Date()) }
    }

    @discardableResult
    func ingest(_ record: SnapshotEnvelope, now: Date = Date()) throws -> Bool {
        // Canonicalize to the browser wire format's millisecond precision before
        // comparing timestamps. A replay of a Swift Date must not become a tiny
        // artificial "new" observation after the first JSON round-trip.
        let validated = try SnapshotEnvelope.decode(JSONEncoder().encode(record.validated(now: now)), now: now)
        return try locked { url in
            var document = try readUnlocked(url, now: now)
            let changed = try document.merge(validated, now: now)
            if changed { try writeUnlocked(document, to: url, now: now) }
            return changed
        }
    }

    func updatePreferences(_ update: (inout QuotaPreferences) -> Void) throws {
        try locked { url in
            let now = Date()
            var document = try readUnlocked(url, now: now)
            update(&document.preferences)
            try writeUnlocked(document, to: url, now: now)
        }
    }
}
