// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitExMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GitExMac",
            path: "Sources/GitExMac"
        ),
        .testTarget(
            name: "GitExMacTests",
            dependencies: ["GitExMac"],
            path: "Tests/GitExMacTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
