import Foundation

struct InstalledApplication: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleURL: URL?

    init(id: String, name: String, bundleURL: URL? = nil) {
        self.id = id
        self.name = name
        self.bundleURL = bundleURL
    }
}
