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
        .target(name: "SICore", path: "mac/SI/Core", resources: [.copy("Resources/Chinese")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "SIStorage", dependencies: ["SICore"], path: "mac/SI/Storage"),
        .target(name: "SIPresentation", dependencies: ["SICore"], path: "mac/SI/InputMethod",
                exclude: ["SIInputController.swift"]),
        .target(name: "SISettings", dependencies: ["SICore", "SIStorage"], path: "mac/SI/Settings",
                exclude: ["SettingsView.swift", "CandidatePreviewView.swift", "PersonalizationView.swift",
                          "LearnedPreferencesView.swift", "UserDictionarySection.swift", "UserDictionaryView.swift",
                          "UserPhraseEditor.swift", "UserDictionaryDocument.swift", "PhraseEditorRequest.swift",
                          "UpdateSettingsSection.swift"]),
        .testTarget(name: "SICoreTests", dependencies: ["SICore"], path: "Tests/SICoreTests"),
        .testTarget(name: "SIStorageTests", dependencies: ["SIStorage", "SICore"], path: "Tests/SIStorageTests"),
        .testTarget(name: "SISettingsTests", dependencies: ["SISettings", "SIStorage", "SICore"], path: "Tests/SISettingsTests"),
        .testTarget(name: "SIPresentationTests", dependencies: ["SIPresentation", "SICore"], path: "Tests/SIPresentationTests"),
        .executableTarget(name: "SIBenchmark", dependencies: ["SICore"], path: "Tools/SIBenchmark"),
    ]
)
