// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlackSwanEdit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BlackSwanEditCore", targets: ["BlackSwanEditCore"]),
        .executable(name: "BlackSwanEditCoreTestRunner", targets: ["BlackSwanEditCoreTestRunner"]),
        .executable(name: "BlackSwanEditApp", targets: ["BlackSwanEditApp"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BlackSwanEditCore",
            path: "Sources/BlackSwanEditCore",
            resources: [.copy("Resources/Languages")]
        ),
        .executableTarget(
            name: "BlackSwanEditCoreTestRunner",
            dependencies: ["BlackSwanEditCore"],
            path: "Sources/BlackSwanEditCoreTestRunner"
        ),
        .executableTarget(
            name: "BlackSwanEditApp",
            dependencies: ["BlackSwanEditCore"],
            path: "Sources/BlackSwanEditApp",
            resources: [
                .copy("Resources/Web")
            ]
        ),
        .testTarget(
            name: "BlackSwanEditCoreTests",
            dependencies: ["BlackSwanEditCore"],
            path: "Tests/BlackSwanEditCoreTests"
        ),
    ]
)
