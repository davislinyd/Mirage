// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MirageCore"),
        .executableTarget(name: "mirage-spike", dependencies: ["MirageCore"]),
        .testTarget(name: "MirageCoreTests", dependencies: ["MirageCore"]),
    ]
)
