// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "libdave-swift",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "libdave-swift",
            targets: ["LibDave"]
        ),
    ],
    targets: [
        // Clang target exposing the public DAVE C API headers
        .target(
            name: "CDave",
            path: "Sources/CDave"
        ),
        // Premium Swift wrapper API
        .target(
            name: "LibDave",
            dependencies: [
                "CDave",
                "DaveFramework"
            ],
            path: "Sources/LibDave"
        ),
        // Precompiled C++ framework containing libdave + mlspp + openssl
        .binaryTarget(
            name: "DaveFramework",
            path: "Frameworks/Dave.xcframework"
        ),
        // Test target to verify all operations
        .testTarget(
            name: "LibDaveTests",
            dependencies: ["LibDave"]
        )
    ],
    cxxLanguageStandard: .cxx17
)
