// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Prune",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Prune",
            path: "Sources/Prune",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        )
    ]
)
