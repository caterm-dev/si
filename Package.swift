// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SI",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SICore", targets: ["SICore"]),
        .executable(name: "SIBenchmark", targets: ["SIBenchmark"]),
    ],
    targets: [
        .target(name: "SILocalization", path: "mac/SI/Localization", resources: [.process("Resources")]),
        .target(name: "SICore", path: "mac/SI/Core", resources: [.copy("Resources/Chinese"), .copy("Resources/English")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "SIStorage", dependencies: ["SICore"], path: "mac/SI/Storage"),
        .target(name: "SIPresentation", dependencies: ["SICore", "SILocalization"], path: "mac/SI/InputMethod",
                exclude: ["SIInputController.swift"]),
        .target(name: "SISettings", dependencies: ["SICore", "SIStorage", "SILocalization"], path: "mac/SI/Settings",
                exclude: ["SettingsView.swift", "UserDictionarySection.swift", "UserDictionaryView.swift",
                          "UserPhraseEditor.swift", "UserDictionaryDocument.swift", "PhraseEditorRequest.swift",
                          "UpdateSettingsSection.swift", "ApplicationMemorySection.swift", "ApplicationMemoryView.swift",
                          "ApplicationMemoryRow.swift", "ApplicationPassthroughSection.swift",
                          "ApplicationPassthroughView.swift", "ApplicationPassthroughRow.swift"]),
        .testTarget(name: "SICoreTests", dependencies: ["SICore"], path: "Tests/SICoreTests"),
        .testTarget(name: "SILocalizationTests", dependencies: ["SILocalization"], path: "Tests/SILocalizationTests"),
        .testTarget(name: "SIStorageTests", dependencies: ["SIStorage", "SICore"], path: "Tests/SIStorageTests"),
        .testTarget(name: "SISettingsTests", dependencies: ["SISettings", "SIStorage", "SICore"], path: "Tests/SISettingsTests"),
        .testTarget(name: "SIPresentationTests", dependencies: ["SIPresentation", "SICore"], path: "Tests/SIPresentationTests"),
        .executableTarget(name: "SIBenchmark", dependencies: ["SICore"], path: "Tools/SIBenchmark"),
    ]
)
