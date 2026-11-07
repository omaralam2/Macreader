// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacReader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacReader",
            path: "Sources/MacReader",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
