// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ManagerKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ManagerKit", targets: ["ManagerKit"]),
        .library(name: "GrantryShared", targets: ["GrantryShared"]),
        // Wird vom Xcode-Target `GrantryHelper` (Grantry.xcodeproj) gelinkt; der Helper-Einstieg
        // (`GrantryHelper/main.swift`) liegt ausschließlich dort.
        .library(name: "HelperCore", targets: ["HelperCore"]),
    ],
    targets: [
        .target(name: "GrantryShared"),
        .target(name: "HelperCore", dependencies: ["GrantryShared"]),
        .target(
            name: "ManagerKit",
            dependencies: ["GrantryShared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "TestSupport", dependencies: ["GrantryShared"], path: "Tests/TestSupport"),
        .testTarget(name: "GrantrySharedTests", dependencies: ["GrantryShared", "TestSupport"]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore", "TestSupport"]),
        .testTarget(
            name: "ManagerKitTests",
            dependencies: ["ManagerKit", "HelperCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
