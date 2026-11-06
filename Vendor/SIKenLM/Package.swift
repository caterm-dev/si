// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SIKenLM",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SIKenLM", targets: ["SIKenLM"])],
    targets: [.target(name: "SIKenLM", cxxSettings: [.define("KENLM_MAX_ORDER", to: "6")])],
    cxxLanguageStandard: .cxx14
)
