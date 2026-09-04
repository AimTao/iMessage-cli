// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "imsg",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "imsg",
            path: "Sources/imsg"
        )
    ]
)
