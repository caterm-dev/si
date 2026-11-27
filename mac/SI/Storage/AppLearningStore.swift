import Foundation
import CryptoKit
#if SWIFT_PACKAGE
import SICore
#endif

public actor AppLearningStore {
    public struct Profile: Identifiable, Sendable, Equatable {
        public let id: String
        public let bundle: String
        public let updated: Date
        public let words: Int
        public let grams: Int
    }

    public enum Failure: Error { case storage }
    private let root: URL
    private var sessions: [String: RustAppLearning] = [:]
    private var epoch: UInt64 = 0

    public init(root: URL) { self.root = root }

    public func generation() -> UInt64 { epoch }

    public func observe(bundle: String, paragraphs: [String], expectedGeneration: UInt64? = nil) throws -> Bool {
        guard expectedGeneration == nil || expectedGeneration == epoch else { throw Failure.storage }
        guard paragraphs.reduce(0, { $0 + $1.utf8.count }) <= RustAppLearning.maximumSnapshotBytes else { return false }
        if sessions[bundle] == nil {
            if paragraphs.isEmpty { return false }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try validateRoot()
            guard let session = RustAppLearning(directory: directory(for: bundle), bundle: bundle) else { throw Failure.storage }
            sessions[bundle] = session
        }
        guard let changed = sessions[bundle]?.observe(paragraphs: paragraphs) else { throw Failure.storage }
        return changed
    }

    public func profiles() throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try validateRoot()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in
            var metadataURL = directory.appending(path: "meta-v1.txt")
            if !FileManager.default.fileExists(atPath: metadataURL.path) {
                // Read legacy metadata without modifying data while learning is disabled.
                let pointer = directory.appending(path: "current")
                guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
                let slot = try String(contentsOf: pointer, encoding: .utf8)
                guard ["snapshot-a\n", "snapshot-b\n"].contains(slot) else { throw Failure.storage }
                metadataURL = directory.appending(path: slot.trimmingCharacters(in: .newlines)).appending(path: "meta-v1.txt")
            }
            let metadata = try String(contentsOf: metadataURL, encoding: .utf8).components(separatedBy: "\n")
            guard metadata.count >= 7, metadata[0] == "SI-APP-LEARNING-1",
                  let timestamp = TimeInterval(metadata[2]), let words = Int(metadata[4]), let grams = Int(metadata[5]),
                  directory.lastPathComponent == key(metadata[1]) else { throw Failure.storage }
            return Profile(id: directory.lastPathComponent, bundle: metadata[1], updated: Date(timeIntervalSince1970: timestamp),
                           words: words, grams: grams)
        }.sorted { $0.bundle < $1.bundle }
    }

    public func resetSessions() { epoch &+= 1; sessions.removeAll() }

    public func clear(bundle: String? = nil) throws {
        epoch &+= 1
        if let bundle {
            sessions[bundle] = nil
            let path = directory(for: bundle)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        } else {
            sessions.removeAll()
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
    }

    private func key(_ bundle: String) -> String {
        SHA256.hash(data: Data(bundle.utf8)).map {
            let value = String($0, radix: 16)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }

    private func directory(for bundle: String) -> URL { root.appending(path: key(bundle), directoryHint: .isDirectory) }

    private func validateRoot() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw Failure.storage }
    }
}
