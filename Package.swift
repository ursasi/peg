// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Peg",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Peg",
            path: "Sources/Peg"
        )
    ]
)
