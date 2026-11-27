import Foundation
import CSIRust

/// Storage-only Rust session. Its owning storage actor serializes every call and release.
public final class RustAppLearning {
    public static let maximumSnapshotBytes = Int(si_app_learning_snapshot_byte_limit())
    private let handle: OpaquePointer

    public init?(directory: URL, bundle: String) {
        guard let handle = RustConversion.shared?.openAppLearning(at: directory, bundle: bundle) else { return nil }
        self.handle = handle
    }

    deinit { si_app_learning_close(handle) }

    public func observe(paragraphs: [String]) -> Bool? {
        guard paragraphs.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumSnapshotBytes else { return false }
        var bytes: [UInt8] = []
        let ends = paragraphs.map { paragraph in
            bytes.append(contentsOf: paragraph.utf8)
            return bytes.count
        }
        let result = bytes.withUnsafeBufferPointer { text in
            ends.withUnsafeBufferPointer { ends in
                si_app_learning_observe(handle, text.baseAddress, text.count, ends.baseAddress, ends.count)
            }
        }
        return result < 0 ? nil : result == 1
    }
}
