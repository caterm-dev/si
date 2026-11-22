// TEMP-GEOMETRY-LOG
#if DEBUG
import Darwin
import Foundation

final class CandidateGeometryLog: Sendable {
    static let preferenceKey = "debug.candidateGeometryLogging"
    static let maximumBytes = 2_000_000
    static let shared = CandidateGeometryLog(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/SI/CandidateGeometry.log", directoryHint: .notDirectory),
        isEnabled: { UserDefaults(suiteName: "com.caterm.si")?.bool(forKey: preferenceKey) == true }
    )

    struct Record: Sendable {
        let time: Date
        let bundleID: String
        let markedRange: NSRange
        let selectedRange: NSRange
        let samples: [(index: Int, rect: CGRect)]
        let selectedIndex: Int?
        let screen: CandidatePlacement.Screen?
        let windowFrame: CGRect?

        var line: String {
            let timestamp = time.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            let probes = samples.map { "\($0.index): \(Self.describe($0.rect))" }.joined(separator: ", ")
            let display = screen.map {
                "frame=\(Self.describe($0.frame)) visible=\(Self.describe($0.visibleFrame))"
            } ?? "none"
            let fields = [timestamp, bundleID, NSStringFromRange(markedRange), NSStringFromRange(selectedRange),
                          probes, selectedIndex.map { String($0) } ?? "none", display, Self.describe(windowFrame)]
            return fields.joined(separator: " | ") + "\n"
        }

        private static func describe(_ rect: CGRect?) -> String {
            guard let rect else { return "none" }
            return "(\(rect.origin.x), \(rect.origin.y), \(rect.size.width), \(rect.size.height))"
        }
    }

    private let fileURL: URL
    private let queue: DispatchQueue
    private let isEnabled: @Sendable () -> Bool

    init(fileURL: URL, queue: DispatchQueue = DispatchQueue(label: "com.caterm.si.candidate-geometry", qos: .utility),
         isEnabled: @escaping @Sendable () -> Bool) {
        self.fileURL = fileURL
        self.queue = queue
        self.isEnabled = isEnabled
    }

    func append(_ record: Record) {
        queue.async {
            // The preference may have changed since the positioning pass enqueued this record.
            guard self.isEnabled() else { return }
            try? self.write(Data(record.line.utf8))
        }
    }

    private func write(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        if try file.seekToEnd() > UInt64(Self.maximumBytes - data.count) {
            // Keep the same file for tail -f when starting a new log.
            try file.truncate(atOffset: 0)
        }
        try file.write(contentsOf: data)
    }
}
#endif
