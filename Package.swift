// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DevCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DevCleanerCore",
            targets: ["DevCleanerCore"]
        ),
        .executable(
            name: "DevCleanerApp",
            targets: ["DevCleanerApp"]
        )
    ],
    targets: [
        .target(
            name: "DevCleanerCore",
            path: "Sources/DevCleanerCore"
        ),
        .executableTarget(
            name: "DevCleanerApp",
            dependencies: ["DevCleanerCore"],
            path: "Sources/DevCleanerApp"
        ),
        .testTarget(
            name: "DevCleanerCoreTests",
            dependencies: ["DevCleanerCore"],
            path: "Tests/DevCleanerCoreTests"
        )
    ]
)
