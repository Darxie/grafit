// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Grafit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Grafit",
            path: "Sources/Grafit"
        ),
        .testTarget(
            name: "GrafitTests",
            dependencies: ["Grafit"],
            path: "Tests/GrafitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
