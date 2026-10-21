import Foundation

/// Kategorie, die ein offizielles CLI aufräumt (uv, Homebrew, npm, pnpm, simctl, Docker); ein einziger Eintrag.
/// `measuredPath`: Ordner, den der Befehl verkleinert – für Anzeige und Bilanz; `nil` heißt „Größe unbekannt“.
struct CommandCategoryProvider: StorageCategoryProvider {
    let category: StorageCategory
    let tool: String
    /// Feste, vertrauenswürdige Programmpfade, die die Standardorte ersetzen (z. B. nur `/usr/bin/xcrun`).
    var candidates: [String]? = nil
    let arguments: [String]
    let measuredPath: String?
    /// Interpreter, die neben einem Skript liegen müssen (z. B. `node` für die `env node`-Skripte von npm und pnpm).
    /// Ein eigenständiges Programm braucht keinen, ein Skript mit absolutem Shebang genau diesen Interpreter
    /// (Homebrew-pnpm mit eigenem Node, #220). Ist die Art unklar, müssen sie wie bisher daneben liegen.
    var requiredCompanions: [String] = []
    /// Ordner, der existieren muss, damit der Befehl sinnvoll läuft (z. B. CoreSimulator-Geräte: `/usr/bin/xcrun` gibt
    /// es auf jedem Mac, ohne Xcode öffnet es aber den Installationsdialog der Command Line Tools).
    var requiredPath: String? = nil
    let locator: ToolLocator
    let measurer: any FileSizeMeasuring

    func scan() async -> StorageCategoryReport {
        guard let executable = locator.locate(tool, candidates: candidates), requirementsMet(next: executable) else {
            return StorageCategoryReport(category: category, status: .notInstalled, items: [])
        }
        let size = if let measuredPath { await measurer.measure(measuredPath) } else { FileSize.unknown }
        // Titel: der lesbare Befehl ohne `env`-Vorsatz; die Bestätigung zeigt die volle `commandLine` des Specs.
        let title = ([executable] + arguments).joined(separator: " ")
        // Ohne Messort ist „unbekannt“ gewollt; eine abgelaufene Messung lässt dagegen Zweifel (#220).
        let item = StorageItem(id: "command:" + category.id, title: title,
                               path: measuredPath, size: size, removal: .command(spec(for: executable)),
                               isPreselected: category.risk == .low && (measuredPath == nil || size.permitsPreselection))
        return StorageCategoryReport(category: category, status: .available, items: [item])
    }

    func spec(for executable: String) -> CommandSpec { CommandSpec.tool(executable, arguments) }

    private func requirementsMet(next executable: String) -> Bool {
        companionsPresent(for: executable) && (requiredPath.map(locator.isDirectory) ?? true)
    }

    private func companionsPresent(for executable: String) -> Bool {
        guard !requiredCompanions.isEmpty else { return true }
        let kind = locator.kind(executable)
        if kind == .binary { return true }
        let directory = (executable as NSString).deletingLastPathComponent
        return requiredCompanions.allSatisfy { companion in
            if case .script(let interpreter) = kind, (interpreter as NSString).lastPathComponent == companion {
                return locator.isExecutable(interpreter)
            }
            return locator.isExecutable(directory + "/" + companion)
        }
    }
}
