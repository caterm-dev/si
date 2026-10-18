// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SI",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SICore", targets: ["SICore"])],
    targets: [
        .target(name: "SICore", path: "mac/SI/Core"),
        .testTarget(name: "SICoreTests", dependencies: ["SICore"], path: "Tests/SICoreTests"),
    ]
)
