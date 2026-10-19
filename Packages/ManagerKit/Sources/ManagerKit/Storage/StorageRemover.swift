import Foundation
import GrantryShared

/// Führt den Löschweg der gewählten Einträge aus (Spec Speicher §2.4, §3): je Eintrag unmittelbar vorher
/// `StoragePathGuard` und – in Kategorien mit `processLock` – die Prüfung, dass kein Build den Eintrag benutzt
/// (#226); Fehler nur für diesen Eintrag. Endgültig gelöscht wird nur bei Risiko „niedrig“, in Nur-Bericht-Kategorien
/// nie etwas; CLI-Befehle laufen höchstens `commandTimeout`, ihre Bilanz ist Größe vorher minus nachher.
public struct StorageRemover: Sendable {
    public static let commandTimeout: Duration = .seconds(10 * 60)
    static let cancelledReason = "Abgebrochen"
    static let stderrLineCount = 5

    let pathGuard: StoragePathGuard
    let trash: any TrashPerforming
    let runner: any CommandRunning
    let measurer: any FileSizeMeasuring
    let openFiles: any OpenFileProbing

    init(pathGuard: StoragePathGuard, trash: any TrashPerforming, runner: any CommandRunning, measurer: any FileSizeMeasuring,
         openFiles: any OpenFileProbing = LibprocOpenFileProbe()) {
        self.pathGuard = pathGuard
        self.trash = trash
        self.runner = runner
        self.measurer = measurer
        self.openFiles = openFiles
    }

    /// Mit den echten Abhängigkeiten der App.
    public init(trash: any TrashPerforming) {
        self.init(pathGuard: StoragePathGuard(), trash: trash, runner: ProcessCommandRunner(),
                  measurer: FileSizeCalculator(timeout: FileSizeCalculator.appTimeout))
    }

    public func clean(_ items: [StorageItem], in category: StorageCategory) async -> [StorageCleanOutcome] {
        await clean(items, in: category, afterCommand: {})
    }

    /// `afterCommand` (nur Tests) läuft zwischen erfolgreichem Befehl und zweiter Messung. Nach einem Abbruch werden
    /// die übrigen Einträge nicht mehr angefasst, aber als „Abgebrochen“ gemeldet – Protokoll und Zählung bleiben
    /// vollständig.
    func clean(_ items: [StorageItem], in category: StorageCategory,
               afterCommand: @Sendable () -> Void) async -> [StorageCleanOutcome] {
        var outcomes: [StorageCleanOutcome] = []
        for item in items {
            if Task.isCancelled {
                outcomes.append(Self.outcome(item, in: category, freed: nil, .skipped(Self.cancelledReason)))
            } else {
                outcomes.append(await clean(item, in: category, afterCommand: afterCommand))
            }
        }
        return outcomes
    }

    private static func outcome(_ item: StorageItem, in category: StorageCategory, freed: Int64?,
                                _ result: StorageCleanOutcome.Result) -> StorageCleanOutcome {
        let target = if case .command(let spec) = item.removal { spec.commandLine } else { item.path ?? item.title }
        return StorageCleanOutcome(categoryID: category.id, target: target, method: item.removal.outcomeMethod,
                                   freedBytes: freed, result: result)
    }

    private func clean(_ item: StorageItem, in category: StorageCategory,
                       afterCommand: @Sendable () -> Void) async -> StorageCleanOutcome {
        let method = item.removal.outcomeMethod
        func outcome(_ freed: Int64?, _ result: StorageCleanOutcome.Result) -> StorageCleanOutcome {
            Self.outcome(item, in: category, freed: freed, result)
        }
        switch item.removal {
        // Nur-Bericht gilt für die ganze Kategorie, auch wenn ein Eintrag (fehlerhaft) einen Löschweg trägt.
        case .none, _ where category.risk == .reportOnly:
            return outcome(nil, .skipped("Nur Bericht"))
        case .command(let spec):
            return await run(spec, item, afterCommand: afterCommand, outcome: outcome)
        case .delete, .trash:
            guard let path = item.path else { return outcome(nil, .skipped("Kein Pfad")) }
            if method == .delete, category.risk != .low {
                return outcome(nil, .skipped("Endgültiges Löschen nur bei geringem Risiko"))
            }
            let verify: @Sendable (LeftoverCandidate) -> RemovalVerdict = { [pathGuard, openFiles] _ in
                let verdict = pathGuard.check(path, identity: item.identity, roots: category.roots)
                guard verdict == .allowed else { return verdict }
                return openFiles.verdict(for: path, lock: category.processLock)
            }
            let candidate = LeftoverCandidate(path: path, kind: .storage, confidence: .safe, size: item.size,
                                              identity: item.identity)
            // Vorab für beide Wege; der Papierkorb prüft mit `verify` zusätzlich unmittelbar vor dem Apple Event.
            if case .blocked(let reason) = verify(candidate) { return outcome(nil, .skipped(reason)) }
            if method == .delete {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    return outcome(item.size.bytes, .removed)
                } catch {
                    return outcome(nil, .failed(error.localizedDescription))
                }
            }
            let report = await trash.moveToTrash([candidate], verifying: verify)
            switch report.outcomes[path] {
            case .trashed: return outcome(item.size.bytes, .removed)
            // Das Original liegt im Papierkorb, aber ein laufendes Programm hat den Ordner neu angelegt: Der Platz ist
            // wieder belegt, eine Bilanz wäre geschönt.
            case .recreated: return outcome(nil, .removed)
            case .blocked(let reason): return outcome(nil, .skipped(reason))
            case .remaining(let reason): return outcome(nil, .failed(reason))
            case nil: return outcome(nil, .failed(report.failure ?? "Kein Ergebnis vom Finder"))
            }
        }
    }

    private func run(_ spec: CommandSpec, _ item: StorageItem, afterCommand: @Sendable () -> Void,
                     outcome: (Int64?, StorageCleanOutcome.Result) -> StorageCleanOutcome) async -> StorageCleanOutcome {
        let before = if let path = item.path { await measurer.measure(path) } else { FileSize.unknown }
        let result: CommandResult
        do {
            result = try await runner.run(spec.executable, spec.arguments, timeout: Self.commandTimeout)
        } catch CommandError.timedOut {
            return outcome(nil, .failed("Zeitüberschreitung"))
        } catch {
            // `ProcessCommandRunner` beendet den Prozess beim Abbruch und wirft `CancellationError`.
            if error is CancellationError || Task.isCancelled { return outcome(nil, .skipped(Self.cancelledReason)) }
            return outcome(nil, .failed(error.localizedDescription))
        }
        guard result.succeeded else {
            let tail = result.stderr.split(separator: "\n").suffix(Self.stderrLineCount).joined(separator: "\n")
            return outcome(nil, .failed("Exit \(result.exitCode): \(tail)"))
        }
        afterCommand()
        let after = if let path = item.path { await measurer.measure(path) } else { FileSize.unknown }
        let freed = before.bytes.flatMap { old in after.bytes.map { max(0, old - $0) } }
        return outcome(freed, .removed)
    }
}
