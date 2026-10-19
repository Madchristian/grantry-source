import Foundation
import GrantryShared

/// Simulator-Laufzeiten (#226) laut `xcrun simctl runtime list -j`: je Laufzeit ein Eintrag mit der von `simctl`
/// gemeldeten Größe, „zuletzt benutzt“ und der Kennzeichnung der neuesten je Plattform. Entfernt wird mit
/// `xcrun simctl runtime delete <UUID>` – nur bei `deletable` und gültiger UUID, damit nie der Alias `all` oder eine
/// Option entsteht. Risiko „mittel“: nie vorausgewählt. Nur mit CoreSimulator-Geräten (`requiredPath`), sonst öffnet
/// `/usr/bin/xcrun` ohne Xcode den Installationsdialog der Command Line Tools.
struct SimulatorRuntimesProvider: StorageCategoryProvider {
    static let timeout: Duration = .seconds(30)

    let requiredPath: String
    let runner: any CommandRunning
    let locator: ToolLocator
    var now: @Sendable () -> Date = { Date() }

    var category: StorageCategory {
        StorageCategory(id: "simulatorRuntimes", title: "Simulator-Laufzeiten", summary: """
                        iOS-, watchOS-, tvOS- und visionOS-Laufzeiten der Simulatoren. Löschen fährt gebootete \
                        Simulatoren der Laufzeit herunter, ihre Geräte werden unbenutzbar; macOS gibt den Platz im \
                        Hintergrund frei.
                        """, risk: .medium, roots: [])
    }

    func scan() async -> StorageCategoryReport {
        let xcrun = BootedSimulatorReader.xcrun
        guard locator.locate("xcrun", candidates: [xcrun]) != nil, locator.isDirectory(requiredPath) else {
            return StorageCategoryReport(category: category, status: .notInstalled, items: [])
        }
        let list = CommandSpec.tool(xcrun, ["simctl", "runtime", "list", "-j"])
        let result: CommandResult
        do {
            result = try await runner.run(list.executable, list.arguments, timeout: Self.timeout)
        } catch {
            return StorageCategoryReport(category: category, status: .failed(error.readableDescription), items: [])
        }
        guard result.succeeded else {
            return StorageCategoryReport(category: category, status: .failed(BootedSimulatorError(message: result.stderr)
                .errorDescription ?? "simctl ist gescheitert"), items: [])
        }
        guard let runtimes = try? Self.parse(Data(result.stdout.utf8)) else {
            return StorageCategoryReport(category: category, status: .failed("Ausgabe von simctl nicht lesbar"), items: [])
        }
        return StorageCategoryReport(category: category, status: .available, items: items(for: runtimes))
    }

    /// Eine Laufzeit aus `simctl runtime list -j` (nur die genutzten Felder).
    struct Runtime: Decodable, Hashable {
        let identifier: String
        let version: String?
        let build: String?
        let platformIdentifier: String?
        let runtimeIdentifier: String?
        let sizeBytes: Int64?
        let deletable: Bool?
        let lastUsedAt: String?
        let state: String?

        /// „iOS 27.0“ aus der Laufzeitkennung, sonst die Version.
        var name: String {
            runtimeIdentifier.map(BootedSimulatorReader.runtimeName) ?? DisplayText.singleLine(version ?? identifier)
        }

        /// Plattform für „neueste je Plattform“; ohne Kennung der erste Teil des Namens.
        var platform: String { platformIdentifier ?? String(name.split(separator: " ").first ?? "") }

        /// Versionsteile als Zahlen („26.5“ → [26, 5]); Unlesbares zählt als 0.
        var versionParts: [Int] { (version ?? "").split(separator: ".").map { Int($0) ?? 0 } }

        var lastUsed: Date? {
            guard let lastUsedAt else { return nil }
            return (try? Date(lastUsedAt, strategy: .iso8601))
                ?? (try? Date(lastUsedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
    }

    static func parse(_ data: Data) throws -> [Runtime] {
        Array(try JSONDecoder().decode([String: Runtime].self, from: data).values)
    }

    /// Je Plattform die neueste zuerst; Plattformen nach Namen.
    func items(for runtimes: [Runtime]) -> [StorageItem] {
        let byPlatform = Dictionary(grouping: runtimes, by: \.platform)
        return byPlatform.keys.sorted().flatMap { platform in
            let sorted = (byPlatform[platform] ?? []).sorted(by: Self.isNewer)
            return sorted.enumerated().map { index, runtime in item(for: runtime, isNewest: index == 0) }
        }
    }

    private func item(for runtime: Runtime, isNewest: Bool) -> StorageItem {
        let isDeletable = runtime.deletable == true && UUID(uuidString: runtime.identifier) != nil
        var details: [String] = []
        if isNewest { details.append("neueste \(runtime.name.split(separator: " ").first ?? "")-Laufzeit") }
        details.append(AppTexts.lastUsed(runtime.lastUsed, now: now()))
        if let state = runtime.state, state != "Ready" { details.append("Zustand: \(DisplayText.singleLine(state))") }
        if !isDeletable { details.append("laut simctl nicht löschbar") }
        let removal: RemovalMethod = isDeletable
            ? .command(CommandSpec.tool(BootedSimulatorReader.xcrun, ["simctl", "runtime", "delete", runtime.identifier]))
            : .none
        let title = runtime.build.map { "\(runtime.name) (\(DisplayText.singleLine($0)))" } ?? runtime.name
        return StorageItem(id: "runtime:" + runtime.identifier, title: title, path: nil,
                           size: runtime.sizeBytes.map(FileSize.bytes) ?? .unknown, removal: removal, isPreselected: false,
                           detail: details.joined(separator: " · "), commandRemovesItem: true)
    }

    /// Höhere Version zuerst; bei gleicher Version der spätere Build.
    private static func isNewer(_ lhs: Runtime, _ rhs: Runtime) -> Bool {
        if lhs.versionParts != rhs.versionParts { return rhs.versionParts.lexicographicallyPrecedes(lhs.versionParts) }
        return (lhs.build ?? "") > (rhs.build ?? "")
    }
}
