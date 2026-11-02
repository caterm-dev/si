import Foundation
import CoreML
import CryptoKit
#if SWIFT_PACKAGE
import SICore
#endif

/// Model and tensors are actor-owned; no client objects, input history or disk writes.
actor SmallReranker {
    static let shared = SmallReranker()
    private var model: MLModel?
    private var tokenizer: SmallRerankerTokenizer?
    private var failedToLoad = false
    private let directory: URL?

    init(directory: URL? = SmallRerankerResources.directory) { self.directory = directory }

    private func prepare() throws {
        if model != nil { return }
        guard !failedToLoad, let directory else { throw CocoaError(.fileReadNoSuchFile) }
        do {
            struct Manifest: Decodable {
                let schemaVersion: Int
                let contextLength: Int
                let batchSize: Int
                let tokenizerSHA256: String
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appending(path: "runtime.json")))
            let data = try Data(contentsOf: directory.appending(path: "tokenizer.json"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard manifest.schemaVersion == 1, manifest.contextLength == 256, manifest.batchSize == 4,
                  manifest.tokenizerSHA256 == digest else { throw CocoaError(.fileReadCorruptFile) }
            let tokenizer = try SmallRerankerTokenizer(data: data)
            let configuration = MLModelConfiguration()
            // Preserve the validated FP32 path initially; benchmark other units separately.
            configuration.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: directory.appending(path: "SmallReranker.mlmodelc"), configuration: configuration)
            self.tokenizer = tokenizer
            self.model = model
        } catch {
            failedToLoad = true
            throw error
        }
    }

    func scores(for candidates: [InputCandidate]) async throws -> [String: Double] {
        try prepare()
        guard model != nil, let tokenizer else { throw CocoaError(.fileReadCorruptFile) }
        let pool = Array(candidates.filter(CandidateFusion.eligible).prefix(CandidateFusion.maximumCandidates))
        // Match Python's all-pool abstention for overlong/unsupported candidates.
        let encoded = try pool.map { candidate -> [Int32] in
            guard let tokens = tokenizer.encode(candidate.text) else { throw CocoaError(.coderInvalidValue) }
            return tokens
        }
        var result: [String: Double] = [:]
        for offset in stride(from: 0, to: pool.count, by: 4) {
            let count = min(4, pool.count - offset)
            let width = encoded[offset..<(offset + count)].map(\.count).max() ?? 1
            let shape: [NSNumber] = [4, NSNumber(value: width)]
            let tokens = try MLMultiArray(shape: shape, dataType: .int32)
            let targets = try MLMultiArray(shape: shape, dataType: .int32)
            let mask = try MLMultiArray(shape: shape, dataType: .float32)
            for index in 0..<(4 * width) {
                tokens[index] = 4
                targets[index] = 4
                mask[index] = 0
            }
            for row in 0..<count {
                let values = encoded[offset + row]
                for column in values.indices {
                    let index = row * width + column
                    tokens[index] = NSNumber(value: column == 0 ? 1 : values[column - 1])
                    targets[index] = NSNumber(value: values[column])
                    mask[index] = 1
                }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["tokens": tokens, "targets": targets, "mask": mask])
            let scores = try predict(input)
            for row in 0..<count {
                let value = scores[row]
                guard value.isFinite, value <= 0 else { throw CocoaError(.coderInvalidValue) }
                result[pool[offset + row].id] = value
            }
        }
        return result
    }

    private func predict(_ input: any MLFeatureProvider) throws -> [Double] {
        // The SDK's async overload sends a non-Sendable MLModel out of this actor.
        // Use its synchronous API on the worker actor instead; no unsafe isolation bridge.
        guard let model else { throw CocoaError(.fileReadCorruptFile) }
        let prediction = try model.prediction(from: input)
        guard let scores = prediction.featureValue(for: "scores")?.multiArrayValue, scores.count == 4 else {
            throw CocoaError(.coderInvalidValue)
        }
        return (0..<4).map { scores[$0].doubleValue }
    }
}
