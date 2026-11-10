import Foundation
import GrantryShared

/// Nur Bericht (Simulatoren, LLM-Modelle, VMs, Steam, Agent-Worktrees, Papierkorb): vorhandene Pfade mit Größe, nicht
/// wählbar; die Ansicht bietet „Im Finder zeigen“. `paths` wird je Scan neu ermittelt (Code-Wurzeln ändern sich).
/// Größen begrenzt parallel.
struct ReportOnlyProvider: StorageCategoryProvider {
    let category: StorageCategory
    let paths: @Sendable () -> [String]
    let measurer: any FileSizeMeasuring

    var locations: [StorageCategoryLocation] { paths().map { StorageCategoryLocation(path: $0) } }

    func scan() async -> StorageCategoryReport {
        let existing = paths().filter { path in
            guard let identity = FileIdentity.of(path) else { return false }
            return identity.type != .symbolicLink
        }
        let sizes = await ConcurrentMeasurement.sizes(of: existing, measurer: measurer)
        let items = zip(existing, sizes).map { path, size in
            StorageItem(id: path, title: (path as NSString).abbreviatingWithTildeInPath, path: path, size: size,
                        removal: .none, isPreselected: false)
        }
        let status: StorageCategoryStatus = items.isEmpty ? .notInstalled
            : items.allSatisfy { $0.size == .unreadable } ? .needsFullDiskAccess : .available
        return StorageCategoryReport(category: category, status: status, items: items)
    }
}

/// Lokale Time-Machine-Snapshots (nur Bericht): `tmutil listlocalsnapshots /`; je Snapshot der Befehl zum Löschen.
/// Der Helper bleibt unverändert (Spec Speicher, Entscheidungen).
struct TimeMachineSnapshotsProvider: StorageCategoryProvider {
    static let prefix = "com.apple.TimeMachine."
    static let suffix = ".local"
    static let categoryID = "timeMachine"
    static let tmutil = "/usr/bin/tmutil"
    static let listArguments = ["listlocalsnapshots", "/"]

    let runner: any CommandRunning

    var category: StorageCategory {
        StorageCategory(id: Self.categoryID, title: "Lokale Time-Machine-Snapshots",
                        summary: "macOS gibt sie bei Platzmangel selbst frei; löschen nur per Terminal.",
                        risk: .reportOnly, roots: [])
    }

    func scan() async -> StorageCategoryReport {
        let result: CommandResult
        do {
            result = try await runner.run(Self.tmutil, Self.listArguments)
        } catch {
            return StorageCategoryReport(category: category, status: .failed(error.localizedDescription), items: [])
        }
        guard result.succeeded else {
            return StorageCategoryReport(category: category, status: .failed(result.failureReason), items: [])
        }
        let items = Self.snapshotDates(in: result.stdout).map { date in
            StorageItem(id: Self.prefix + date + Self.suffix, title: date, path: nil, size: .unknown, removal: .none,
                        isPreselected: false, hint: "sudo tmutil deletelocalsnapshots \(date)")
        }
        return StorageCategoryReport(category: category, status: .available, items: items)
    }

    /// Daten der Snapshots in der Ausgabe von `tmutil listlocalsnapshots /`, in deren Reihenfolge; Kopfzeile und
    /// unpassende Zeilen fallen weg. Einziger Parser dieser Ausgabe (Speicher und Datenträger, #400).
    static func snapshotDates(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            line.split(whereSeparator: \.isWhitespace).first.flatMap(snapshotDate)
        }
    }

    /// Datum aus dem Snapshot-Namen (`com.apple.TimeMachine.<Datum>.local`); Zusätze hinter dem Namen wie
    /// ` (dataless)` stehen außerhalb des Tokens. Nur Buchstaben, Ziffern und `-`, damit der kopierbare
    /// `sudo`-Befehl nie Shell-Sonderzeichen enthält.
    private static func snapshotDate(in token: Substring) -> String? {
        guard token.hasPrefix(prefix), token.hasSuffix(suffix) else { return nil }
        let date = String(token.dropFirst(prefix.count).dropLast(suffix.count))
        let isSafe = date.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        return !date.isEmpty && isSafe ? date : nil
    }
}

extension CommandResult {
    /// stderr, sonst stdout, sonst der Exit-Code (ein leerer Grund wäre in der Ansicht nichtssagend).
    var failureReason: String {
        for text in [stderr, stdout] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Exit-Code \(exitCode)"
    }
}
