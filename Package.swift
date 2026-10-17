// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auxilius",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources are copied into the .app by scripts/build.sh rather than declared here,
        // because SwiftPM's resource bundle would land in the app root where codesign rejects it.
        .executableTarget(name: "Auxilius", path: "Sources/Auxilius"),
    ],
    // Swift 5 mode: capture callbacks hop queues by hand, which strict concurrency checking cannot follow.
    swiftLanguageModes: [.v5]
)
