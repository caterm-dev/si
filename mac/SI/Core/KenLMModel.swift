import CryptoKit
import Darwin
import Foundation
import SIKenLM

/// The native model and its mapped pages are immutable after opening. All advancing
/// states and caches belong to the caller, and retaining this object pins the mapping.
public final class KenLMModel: @unchecked Sendable {
    public static let benchmarkSHA = "0083776ec5acaf9c818ac7cf1eedf9cd955d9c2eb7cbc734cd07bb7e33e20605"
    private let handle: OpaquePointer
    private let number: UInt32
    private let outOfVocabulary: UInt32
    public let sha256: String

    public struct State: Sendable {
        fileprivate var native: SIKenLMState
        fileprivate let owner: ObjectIdentifier
    }

    private init?(url: URL, sha256: String) {
        guard let model = url.path.withCString({ SIKenLMOpen($0) }) else { return nil }
        let number = Self.index("<num>", in: model)
        let oov = Self.index("<oov>", in: model)
        guard number != 0, oov != 0, number != oov else {
            SIKenLMClose(model)
            return nil
        }
        handle = model
        self.number = number
        outOfVocabulary = oov
        self.sha256 = sha256
    }

    deinit { SIKenLMClose(handle) }

    private static func index(_ token: String, in model: OpaquePointer) -> UInt32 {
        token.withCString { SIKenLMIndex(model, $0, token.utf8.count) }
    }

    public func wordIndex(_ token: String) -> (index: UInt32, isOOV: Bool)? {
        guard !KenLMCleaning.rejects(token), let cleaned = KenLMCleaning.baseToken(token) else { return nil }
        if cleaned == "<num>" { return (number, false) }
        if cleaned == "<oov>" { return (outOfVocabulary, true) }
        // The binary vocabulary already encodes the training rare-token policy.
        // Both unprotected rare words and any other missing index map to <oov>.
        let index = Self.index(cleaned, in: handle)
        return index == 0 ? (outOfVocabulary, true) : (index, false)
    }

    public func beginSentence() -> State {
        var state = SIKenLMState()
        SIKenLMBeginSentence(handle, &state)
        return State(native: state, owner: ObjectIdentifier(self))
    }

    public func advance(_ state: State, wordIndex: UInt32) -> (state: State, log10: Double)? {
        guard state.owner == ObjectIdentifier(self) else { return nil }
        var input = state.native
        var output = SIKenLMState()
        let value = SIKenLMAdvance(handle, &input, wordIndex, &output)
        guard value.isFinite else { return nil }
        return (State(native: output, owner: state.owner), Double(value))
    }

    /// Offline evaluation admits only the selected train-only artifact.
    public static func openBenchmark(_ url: URL) throws -> KenLMModel? {
        guard try digest(url) == benchmarkSHA else { return nil }
        return KenLMModel(url: url, sha256: benchmarkSHA)
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Stamp: Decodable {
        let bytes: Int64
        let mtime_seconds: Int
        let mtime_nanos: Int

        static func regularFile(at url: URL) -> stat? {
            var value = stat()
            guard url.path.withCString({ lstat($0, &value) }) == 0,
                  value.st_mode & S_IFMT == S_IFREG else { return nil }
            return value
        }

        func matches(_ url: URL) -> Bool {
            guard let value = Self.regularFile(at: url) else { return false }
            return value.st_size == bytes
                && value.st_mtimespec.tv_sec == mtime_seconds
                && value.st_mtimespec.tv_nsec == mtime_nanos
        }
    }

    private struct Installation: Decodable {
        let schema: Int
        let version: String
        let sha256: String
        let model: Stamp
        let metadata: Stamp
    }

    private struct Metadata: Decodable {
        struct Cleaning: Decodable {
            let version: String
            let module_sha256: String
            let vectors_sha256: String
            let unicode_version: String
            let maximum_scalars: Int
            let rare_threshold_exclusive: Int
        }
        struct Model: Decodable {
            let binary_sha256: String
            let binary_bytes: Int64
            let order: Int
            let a: Int
            let probability_bits: Int
            let backoff_bits: Int
            let prune: [Int]
        }
        struct Tool: Decodable { let binary_format_version: Int }
        let schema_version: Int
        let cleaning: Cleaning
        let model: Model
        let kenlm: Tool
    }

    /// Called once on a background worker. The install/update tool does the streaming
    /// checksum. Opening only reads the small manifests, checks stat data and maps pages.
    public static func openInstalled(at root: URL) -> KenLMModel? {
        let decoder = JSONDecoder()
        guard let index = try? Data(contentsOf: root.appendingPathComponent("current.json")),
              let install = try? decoder.decode(Installation.self, from: index),
              install.schema == 1,
              isSHA256(install.sha256),
              install.version.hasPrefix("v1-" + install.sha256 + "-"),
              install.version.utf8.count == 100,
              install.version.suffix(32).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let directory = root.appendingPathComponent(install.version, isDirectory: true)
        let model = directory.appendingPathComponent("final.bin")
        let meta = directory.appendingPathComponent("final.meta.json")
        guard install.model.matches(model), install.metadata.matches(meta) else { return nil }
        return openCompatibleModel(directory, expectedSHA: install.sha256)
    }

    /// Release packaging hashes the payload before signing it as an app resource.
    /// Package and archive extraction may change modification times.
    public static func openBundled(at directory: URL) -> KenLMModel? {
        openCompatibleModel(directory)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func openCompatibleModel(_ directory: URL, expectedSHA: String? = nil) -> KenLMModel? {
        let model = directory.appendingPathComponent("final.bin")
        let meta = directory.appendingPathComponent("final.meta.json")
        guard let file = Stamp.regularFile(at: model), Stamp.regularFile(at: meta) != nil,
              let bytes = try? Data(contentsOf: meta),
              let record = try? JSONDecoder().decode(Metadata.self, from: bytes),
              record.schema_version == 1, record.kenlm.binary_format_version == 5,
              record.cleaning.version == KenLMCleaning.version,
              record.cleaning.module_sha256 == KenLMCleaning.moduleSHA,
              record.cleaning.vectors_sha256 == KenLMCleaning.vectorsSHA,
              record.cleaning.unicode_version == "15.0.0",
              record.cleaning.maximum_scalars == 32, record.cleaning.rare_threshold_exclusive == 5,
              isSHA256(record.model.binary_sha256),
              expectedSHA == nil || record.model.binary_sha256 == expectedSHA,
              record.model.binary_bytes == file.st_size,
              record.model.order == 4, record.model.a == 22,
              (record.model.prune == [0, 0, 1, 2] || record.model.prune == [0, 1, 2, 3]),
              record.model.probability_bits == 8, record.model.backoff_bits == 8
        else { return nil }
        return KenLMModel(url: model, sha256: record.model.binary_sha256)
    }
}
