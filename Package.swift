// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "libdave-swift",
    platforms: [
        // The bundled Dave.xcframework is built with a macOS 26 deployment
        // target, so the package minimum is aligned to match. Declaring a lower
        // floor would surface as a cryptic link failure instead of a clear
        // "requires macOS 26" diagnostic.
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "libdave-swift",
            targets: ["libdave-swift"]
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
            name: "libdave-swift",
            dependencies: [
                "CDave",
                "DaveFramework"
            ],
            path: "Sources/libdave-swift",
            linkerSettings: [
                // Dave.xcframework is a C-API shim over a C++ implementation
                // (libdave + mlspp). Consumers must link the C++ standard
                // library or the final link fails with unresolved libc++
                // symbols (e.g. ___gxx_personality_v0, ___dynamic_cast).
                // Declaring it here propagates the flag to anything that links
                // this target, so a clean checkout builds without relying on
                // pre-existing build artifacts.
                .linkedLibrary("c++")
            ]
        ),
        // Precompiled C++ framework containing libdave + mlspp + openssl
        .binaryTarget(
            name: "DaveFramework",
            path: "Frameworks/Dave.xcframework"
        ),
        // Test target to verify all operations
        .testTarget(
            name: "libdave-swiftTests",
            dependencies: ["libdave-swift"],
            path: "Tests/libdave-swiftTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
