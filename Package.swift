// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SICore", targets: ["SICore"]),
        .executable(name: "SIBenchmark", targets: ["SIBenchmark"]),
    ],
    targets: [
        .target(name: "SICore", path: "mac/SI/Core"),
        .target(name: "SIStorage", dependencies: ["SICore"], path: "mac/SI/Storage"),
        .target(name: "SISettings", dependencies: ["SICore", "SIStorage"], path: "mac/SI/Settings",
                exclude: ["SettingsView.swift", "CandidatePreviewView.swift", "PersonalizationView.swift",
                          "LearnedPreferencesView.swift", "UserDictionarySection.swift", "UserDictionaryView.swift",
                          "UserPhraseEditor.swift", "UserDictionaryDocument.swift", "PhraseEditorRequest.swift"]),
        .testTarget(name: "SICoreTests", dependencies: ["SICore"], path: "Tests/SICoreTests"),
        .testTarget(name: "SIStorageTests", dependencies: ["SIStorage", "SICore"], path: "Tests/SIStorageTests"),
        .testTarget(name: "SISettingsTests", dependencies: ["SISettings", "SIStorage", "SICore"], path: "Tests/SISettingsTests"),
        .executableTarget(name: "SIBenchmark", dependencies: ["SICore"], path: "Tools/SIBenchmark"),
    ]
)
