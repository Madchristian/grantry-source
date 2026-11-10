// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ManagerKit",
    platforms: [.macOS("26.0")],
    products: [
        // `GrantryCharts` liegt im Produkt ManagerKit, damit die App es ohne eigene Paketabhängigkeit importiert.
        .library(name: "ManagerKit", targets: ["ManagerKit", "GrantryCharts"]),
        .executable(name: "GrantryChartsDemo", targets: ["GrantryChartsDemo"]),
        .library(name: "GrantryShared", targets: ["GrantryShared"]),
        // Wird vom Xcode-Target `GrantryHelper` (Grantry.xcodeproj) gelinkt; der Helper-Einstieg
        // (`GrantryHelper/main.swift`) liegt ausschließlich dort.
        .library(name: "HelperCore", targets: ["HelperCore"]),
    ],
    targets: [
        .target(name: "GrantryShared"),
        // Graphen des Task-Managers (Spec 2026-11-06 §4); bewusst ohne Abhängigkeit zu ManagerKit.
        .target(name: "GrantryCharts"),
        // Prototyp mit Fake-Daten zur Abnahme (TM-2.9): `swift run --package-path Packages/ManagerKit GrantryChartsDemo`.
        .executableTarget(name: "GrantryChartsDemo", dependencies: ["GrantryCharts"]),
        .target(name: "HelperCore", dependencies: ["GrantryShared"]),
        .target(
            name: "ManagerKit",
            dependencies: ["GrantryShared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "TestSupport", dependencies: ["GrantryShared"], path: "Tests/TestSupport"),
        .testTarget(name: "GrantryChartsTests", dependencies: ["GrantryCharts"]),
        .testTarget(
            name: "GrantrySharedTests",
            dependencies: ["GrantryShared", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore", "TestSupport"]),
        .testTarget(
            name: "ManagerKitTests",
            dependencies: ["ManagerKit", "HelperCore", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
