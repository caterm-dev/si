import Foundation
import Testing
@testable import SIPresentation

struct AICompletionExecutableTests {
    @Test func deletedPathEntryDoesNotHideTheNextExecutable() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let missing = home.appendingPathComponent("deleted/bin")
        let installed = try makeExecutable(in: home, path: "node version/bin/codex")
        let resolved = await AICompletionExecutable.resolve(
            provider: .codex, configuredPath: nil,
            environment: ["PATH": "\(missing.path):\(installed.deletingLastPathComponent().path)"],
            home: home, systemDirectories: []
        )
        #expect(resolved == installed.path)
        // A user-specified missing path is actionable and must not silently select another program.
        let override = await AICompletionExecutable.resolve(
            provider: .codex, configuredPath: missing.appendingPathComponent("codex").path,
            environment: ["PATH": installed.deletingLastPathComponent().path], home: home, systemDirectories: []
        )
        #expect(override == nil)
    }

    @Test func terminalPathTakesPriorityOverAnOlderLocalInstall() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try makeExecutable(in: home, path: ".local/bin/codex")
        let preferred = try makeExecutable(in: home, path: "terminal/bin/codex")
        let resolved = await AICompletionExecutable.resolve(
            provider: .codex, configuredPath: nil,
            environment: ["PATH": preferred.deletingLastPathComponent().path], home: home, systemDirectories: []
        )
        #expect(resolved == preferred.path)
    }

    @Test func guiPathCanFindNVMAndManualPathsSupportTildeAndSpaces() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try makeExecutable(in: home, path: ".nvm/versions/node/v9.0.0/bin/codex")
        let newest = try makeExecutable(in: home, path: ".nvm/versions/node/v24.0.0/bin/codex")
        let automatic = await AICompletionExecutable.resolve(provider: .codex, configuredPath: nil,
                                                              environment: [:], home: home, systemDirectories: [])
        #expect(automatic.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == newest.resolvingSymlinksInPath().path)
        let manual = try makeExecutable(in: home, path: "custom cli/codex")
        let chosen = await AICompletionExecutable.resolve(provider: .codex, configuredPath: " ~/custom cli/codex ",
                                                           environment: [:], home: home, systemDirectories: [])
        #expect(chosen == manual.path)
        let relative = await AICompletionExecutable.resolve(provider: .codex, configuredPath: "custom cli/codex",
                                                             environment: [:], home: home, systemDirectories: [])
        #expect(relative == nil)
        let directory = await AICompletionExecutable.resolve(provider: .codex, configuredPath: home.path,
                                                              environment: [:], home: home, systemDirectories: [])
        #expect(directory == nil)
    }

    private func makeExecutable(in home: URL, path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
