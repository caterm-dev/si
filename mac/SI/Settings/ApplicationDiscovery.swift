import Foundation

/// Read application metadata only while the Settings application list is open.
actor ApplicationDiscovery {
    static let shared = ApplicationDiscovery()

    func applications(in roots: [URL]? = nil, including additionalURLs: [URL] = []) -> [InstalledApplication] {
        let manager = FileManager.default
        let directories = roots ?? manager.urls(for: .applicationDirectory,
                                                in: [.localDomainMask, .systemDomainMask, .userDomainMask])
        var urls = additionalURLs
        for directory in directories {
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return [] }
                if url.pathExtension.lowercased() == "app" {
                    urls.append(url)
                    enumerator.skipDescendants()
                }
            }
        }
        var byID: [String: InstalledApplication] = [:]
        for url in Set(urls).sorted(by: { $0.path < $1.path }) {
            if Task.isCancelled { return [] }
            guard let application = application(at: url), byID[application.id] == nil else { continue }
            byID[application.id] = application
        }
        return byID.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func application(at url: URL) -> InstalledApplication? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = [displayName, bundleName].compactMap { $0 }.first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(id: id, name: name, bundleURL: url)
    }
}
