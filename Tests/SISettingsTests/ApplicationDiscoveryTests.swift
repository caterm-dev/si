import Foundation
import Testing
@testable import SISettings

struct ApplicationDiscoveryTests {
    @Test func discoversGroupedApplicationsWithoutNestedHelpersAndDeduplicatesCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SI.AppDiscovery.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try makeApplication(in: root.appending(path: "Utilities"), name: "Terminal",
                                           id: "com.example.Terminal", displayName: "Example Terminal")
        _ = try makeApplication(in: terminal.appending(path: "Contents/Helpers"), name: "Helper", id: "com.example.Helper")
        _ = try makeApplication(in: root.appending(path: "Copies"), name: "Terminal Copy", id: "com.example.Terminal")
        _ = try makeApplication(in: root, name: "Browser", id: "com.example.Browser")
        let outside = try makeApplication(in: root.appending(path: "Elsewhere"), name: "Editor", id: "com.example.Editor")
        let discovery = ApplicationDiscovery()
        let applications = await discovery.applications(in: [root], including: [terminal, outside])
        #expect(Set(applications.map(\.id)) == ["com.example.Terminal", "com.example.Browser", "com.example.Editor"])
        #expect(applications.count == 3)
        #expect(applications.first?.name == "Browser")
        #expect(await discovery.application(at: terminal)
            == InstalledApplication(id: "com.example.Terminal", name: "Example Terminal", bundleURL: terminal))
    }

    @Test func includesSelectedAppsOutsideSearchRootsAndRejectsMissingIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SI.AppDiscovery.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try makeApplication(in: root, name: "Other App", id: "com.example.Other")
        let invalid = try makeApplication(in: root, name: "Invalid", id: "")
        let discovery = ApplicationDiscovery()
        #expect(await discovery.applications(in: [], including: [selected, invalid])
            == [InstalledApplication(id: "com.example.Other", name: "Other App", bundleURL: selected)])
        #expect(await discovery.application(at: invalid) == nil)
        #expect(await discovery.application(at: root) == nil)
    }

    private func makeApplication(in root: URL, name: String, id: String, displayName: String? = nil) throws -> URL {
        let url = root.appending(path: "\(name).app")
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        if let displayName { info["CFBundleDisplayName"] = displayName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        return url
    }
}
