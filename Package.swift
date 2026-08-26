// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SGLangDesktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SGLangDesktop", targets: ["SGLangDesktopApp"]),
        .library(name: "SGLangDesktopCore", targets: ["SGLangDesktopCore"]),
    ],
    targets: [
        .target(
            name: "SGLangDesktopCore",
            path: "Sources/SGLangDesktopCore"
        ),
        .executableTarget(
            name: "SGLangDesktopApp",
            dependencies: ["SGLangDesktopCore"],
            path: "Sources/SGLangDesktopApp"
        ),
        .testTarget(
            name: "SGLangDesktopCoreTests",
            dependencies: ["SGLangDesktopCore"],
            path: "Tests/SGLangDesktopCoreTests"
        ),
    ]
)
