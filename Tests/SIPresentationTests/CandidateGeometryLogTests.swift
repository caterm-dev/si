// TEMP-GEOMETRY-LOG
#if DEBUG
import Foundation
import Testing
@testable import SIPresentation

struct CandidateGeometryLogTests {
    private let record = CandidateGeometryLog.Record(
        time: Date(timeIntervalSince1970: 0.125), bundleID: "com.example.synthetic",
        markedRange: NSRange(location: 12, length: 4), selectedRange: NSRange(location: 16, length: 0),
        samples: [(12, .zero), (16, CGRect(x: 10, y: 20, width: 0, height: 18))], selectedIndex: 16,
        screen: .init(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                      visibleFrame: CGRect(x: 0, y: 24, width: 800, height: 576)),
        windowFrame: CGRect(x: 10, y: 38, width: 160, height: 36)
    )

    @Test func appendsOneCopyableLinePerPlacement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Geometry.log")
        let queue = DispatchQueue(label: "CandidateGeometryLogTests.append")
        let log = CandidateGeometryLog(fileURL: file, queue: queue, isEnabled: { true })
        log.append(record)
        log.append(record)
        queue.sync {}

        let expected = [
            "1970-01-01T00:00:00.125Z", "com.example.synthetic", "{12, 4}", "{16, 0}",
            "12: (0.0, 0.0, 0.0, 0.0), 16: (10.0, 20.0, 0.0, 18.0)", "16",
            "frame=(0.0, 0.0, 800.0, 600.0) visible=(0.0, 24.0, 800.0, 576.0)",
            "(10.0, 38.0, 160.0, 36.0)",
        ].joined(separator: " | ") + "\n"
        #expect(try String(contentsOf: file, encoding: .utf8) == expected + expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func disabledLoggingNeitherCreatesNorChangesTheFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Geometry.log")
        let queue = DispatchQueue(label: "CandidateGeometryLogTests.disabled")
        let log = CandidateGeometryLog(fileURL: file, queue: queue, isEnabled: { false })
        log.append(record)
        queue.sync {}
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = Data("previous record\n".utf8)
        try previous.write(to: file)
        log.append(record)
        queue.sync {}
        #expect(try Data(contentsOf: file) == previous)
    }

    @Test func exceedingTwoMegabytesReplacesTheContentsWithTheCurrentRecord() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Geometry.log")
        let queue = DispatchQueue(label: "CandidateGeometryLogTests.rollover")
        let log = CandidateGeometryLog(fileURL: file, queue: queue, isEnabled: { true })
        let line = Data(record.line.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x78, count: 2_000_000 - line.count).write(to: file)

        log.append(record)
        queue.sync {}
        #expect(try Data(contentsOf: file).count == 2_000_000)
        log.append(record)
        queue.sync {}
        #expect(try Data(contentsOf: file) == line)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "si-geometry-\(UUID())", directoryHint: .isDirectory)
    }
}
#endif
