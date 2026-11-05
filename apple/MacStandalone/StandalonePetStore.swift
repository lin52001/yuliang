import Foundation
import Darwin
import QuotaCore

/// Pet progress is stored independently from quota observations. Losing a
/// connection or changing appearance can never rewrite the provider's usage.
final class StandalonePetStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    private func locked<T>(_ action: (URL) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("pet.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StandaloneStoreError.lockFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StandaloneStoreError.lockFailed }
        defer { flock(descriptor, LOCK_UN) }
        return try action(directory.appendingPathComponent("pet.json"))
    }

    func read(now: Date = Date()) throws -> PetCompanionState {
        try locked { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return PetCompanionState(now: now) }
            let data = try Data(contentsOf: url)
            guard data.count <= 256_000 else { throw StandaloneStoreError.corrupt }
            return try PetCompanionState.decode(data, now: now)
        }
    }

    @discardableResult func write(_ state: PetCompanionState) throws -> PetCompanionState {
        try locked { url in
            let data = try state.encoded()
            guard data.count <= 256_000 else { throw StandaloneStoreError.corrupt }
            let canonical = try PetCompanionState.decode(data)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return canonical
        }
    }
}

enum PetUI {
    static func text(_ zh: String, _ en: String, _ ja: String, language: YuliangLanguage = .system) -> String {
        switch language.resolved { case .en: return en; case .ja: return ja; default: return zh }
    }
}
