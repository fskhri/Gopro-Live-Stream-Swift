// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoProKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "GoProKit", targets: ["GoProKit"]),
    ],
    targets: [
        .target(
            name: "GoProKit",
            path: "Sources/GoProKit"
        ),
        .testTarget(
            name: "GoProKitTests",
            dependencies: ["GoProKit"],
            path: "Tests/GoProKitTests"
        ),
    ]
)
