import Foundation

enum AICompletionExecutable {
    static func normalizedPath(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))).path }
        return trimmed
    }

    /// GUI apps can have a shorter PATH than an interactive shell. Resolve on a
    /// worker and share this search between Settings and the prediction adapter.
    @concurrent
    static func resolve(provider: AICompletionProvider, configuredPath: String?,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        systemDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]) async -> String? {
        guard provider != .openAI else { return nil }
        let manager = FileManager.default
        func executable(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return path.hasPrefix("/") && manager.fileExists(atPath: path, isDirectory: &directory)
                && !directory.boolValue && manager.isExecutableFile(atPath: path)
        }
        if let configuredPath {
            let path = normalizedPath(configuredPath, home: home)
            return executable(path) ? path : nil
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }
        let commonDirectories = [home.appendingPathComponent(".local/bin").path] + systemDirectories
        for directory in pathDirectories + commonDirectories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(provider.rawValue).path
            if executable(path) { return path }
        }
        // NVM does not normally export its Node directories to GUI applications.
        let nodeVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = (try? manager.contentsOfDirectory(at: nodeVersions, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        for version in versions.sorted(by: {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }) {
            let path = version.appendingPathComponent("bin/\(provider.rawValue)").path
            if executable(path) { return path }
        }
        return nil
    }
}
