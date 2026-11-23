// swift-tools-version: 6.2
// Shared code for every Levels target (ADR-0003). Widget extensions link only
// LevelsModel, LevelsUI and LevelsWidgetKit; never LevelsSync or LevelsReaders. The iPhone
// widget may also link LevelsNet (the Mac hub client, ADR-0020; NET-004 variant B).
import PackageDescription

let package = Package(
    name: "Shared",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "LevelsModel", targets: ["LevelsModel"]),
        .library(name: "LevelsSync", targets: ["LevelsSync"]),
        .library(name: "LevelsNet", targets: ["LevelsNet"]),
        .library(name: "LevelsReaders", targets: ["LevelsReaders"]),
        .library(name: "LevelsUI", targets: ["LevelsUI"]),
        .library(name: "LevelsWidgetKit", targets: ["LevelsWidgetKit"]),
    ],
    targets: [
        .target(name: "LevelsModel"),
        .target(name: "LevelsSync", dependencies: ["LevelsModel", "LevelsNet"]),
        // ADR-0020, lead's call 20: Foundation, Network, CryptoKit, Security; no CloudKit, no LevelsSync.
        .target(name: "LevelsNet", dependencies: ["LevelsModel"]),
        .target(name: "LevelsReaders", dependencies: ["LevelsModel"]),
        .target(name: "LevelsUI", dependencies: ["LevelsModel"], resources: [.process("Resources")]),
        .target(name: "LevelsWidgetKit", dependencies: ["LevelsModel", "LevelsUI"]),
        .testTarget(name: "LevelsModelTests", dependencies: ["LevelsModel"]),
        .testTarget(name: "LevelsSyncTests", dependencies: ["LevelsSync", "LevelsNet"]),
        .testTarget(name: "LevelsNetTests", dependencies: ["LevelsNet"]),
        .testTarget(name: "LevelsReadersTests", dependencies: ["LevelsReaders"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LevelsUITests", dependencies: ["LevelsUI"]),
        .testTarget(name: "LevelsWidgetKitTests", dependencies: ["LevelsWidgetKit"]),
    ],
    swiftLanguageModes: [.v6]
)
