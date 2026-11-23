// swift-tools-version: 6.2
// Shared code for every Levels target (ADR-0003). Widget extensions link only
// LevelsModel, LevelsUI and LevelsWidgetKit; never LevelsSync or LevelsReaders.
import PackageDescription

let package = Package(
    name: "Shared",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "LevelsModel", targets: ["LevelsModel"]),
        .library(name: "LevelsSync", targets: ["LevelsSync"]),
        .library(name: "LevelsReaders", targets: ["LevelsReaders"]),
        .library(name: "LevelsUI", targets: ["LevelsUI"]),
        .library(name: "LevelsWidgetKit", targets: ["LevelsWidgetKit"]),
    ],
    targets: [
        .target(name: "LevelsModel"),
        .target(name: "LevelsSync", dependencies: ["LevelsModel"]),
        .target(name: "LevelsReaders", dependencies: ["LevelsModel"]),
        .target(name: "LevelsUI", dependencies: ["LevelsModel"]),
        .target(name: "LevelsWidgetKit", dependencies: ["LevelsModel", "LevelsUI"]),
        .testTarget(name: "LevelsModelTests", dependencies: ["LevelsModel"]),
        .testTarget(name: "LevelsSyncTests", dependencies: ["LevelsSync"]),
        .testTarget(name: "LevelsReadersTests", dependencies: ["LevelsReaders"]),
        .testTarget(name: "LevelsUITests", dependencies: ["LevelsUI"]),
        .testTarget(name: "LevelsWidgetKitTests", dependencies: ["LevelsWidgetKit"]),
    ],
    swiftLanguageModes: [.v6]
)
