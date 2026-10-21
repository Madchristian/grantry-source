import Foundation
import Testing
@testable import ManagerKit

@Suite struct StoragePresentationTests {
    private func report(_ id: String, _ risk: StorageRisk, _ items: [(String, Int64, RemovalMethod)]) -> StorageCategoryReport {
        report(id, risk, sizes: items.map { ($0.0, .bytes($0.1), $0.2) })
    }

    private func report(_ id: String, _ risk: StorageRisk, summary: String = "",
                        sizes items: [(String, FileSize, RemovalMethod)]) -> StorageCategoryReport {
        StorageCategoryReport(
            category: StorageCategory(id: id, title: id, summary: summary, risk: risk, roots: []), status: .available,
            items: items.map { StorageItem(id: $0.0, title: $0.0, path: $0.0, size: $0.1, removal: $0.2,
                                           isPreselected: risk == .low) })
    }

    private func removed(_ target: String, freed: Int64?,
                         method: StorageCleanOutcome.Method = .delete) -> StorageCleanOutcome {
        StorageCleanOutcome(categoryID: "c", target: target, method: method, freedBytes: freed, result: .removed)
    }

    private let dockerPrune = RemovalMethod.command(
        CommandSpec(executable: "/usr/local/bin/docker", arguments: ["system", "prune", "-f"]))

    @Test func confirmationListsMethodsAndHighlightsPermanentRemoval() {
        let reports = [report("caches", .low, [("/a", 1_000_000_000, .delete)]),
                       report("logs", .medium, [("/b", 500_000_000, .trash)])]
        let confirmation = StoragePresentation.confirmation(reports: reports, selection: ["/a", "/b"])
        #expect(confirmation.title == "2 Einträge aufräumen?")
        #expect(confirmation.message?.contains("caches: endgültig löschen") == true)
        #expect(confirmation.message?.contains("logs: in den Papierkorb") == true)
        #expect(confirmation.note == "Endgültig gelöschte Einträge lassen sich nicht wiederherstellen.")
        #expect(confirmation.confirmTitle == "\(AppTexts.formattedSize(1_000_000_000)) freigeben, "
                + "\(AppTexts.formattedSize(500_000_000)) in den Papierkorb legen")
        #expect(confirmation.isDestructive)
    }

    @Test func trashOnlySelectionHasNoPermanentNote() {
        let reports = [report("logs", .medium, [("/b", 10, .trash)])]
        #expect(StoragePresentation.confirmation(reports: reports, selection: ["/b"]).note == nil)
    }

    @Test func summaryCountsOutcomes() {
        let outcomes = [
            StorageCleanOutcome(categoryID: "c", target: "/a", method: .delete, freedBytes: 2_000, result: .removed),
            StorageCleanOutcome(categoryID: "c", target: "/b", method: .trash, freedBytes: nil, result: .skipped("x")),
            StorageCleanOutcome(categoryID: "c", target: "/c", method: .command, freedBytes: nil, result: .failed("y")),
        ]
        #expect(StoragePresentation.summary(outcomes)
                == "\(AppTexts.formattedSize(2_000)) freigegeben, 1 übersprungen, 1 fehlgeschlagen")
    }

    @Test func resultTextNamesSizeOrReason() {
        #expect(StoragePresentation.resultText(removed("/a", freed: 2_000))
                == "aufgeräumt – \(AppTexts.formattedSize(2_000))")
        #expect(StoragePresentation.resultText(removed("/a", freed: nil)) == "aufgeräumt")
        let skipped = StorageCleanOutcome(categoryID: "c", target: "/b", method: .trash, freedBytes: nil,
                                          result: .skipped("Geändert seit Scan"))
        #expect(StoragePresentation.resultText(skipped) == "übersprungen: Geändert seit Scan")
        let failed = StorageCleanOutcome(categoryID: "c", target: "x", method: .command, freedBytes: nil,
                                         result: .failed("Zeitüberschreitung"))
        #expect(StoragePresentation.resultText(failed) == "fehlgeschlagen: Zeitüberschreitung")
    }

    @Test func outcomeMethodTexts() {
        #expect(StoragePresentation.methodText(StorageCleanOutcome.Method.trash) == "Papierkorb")
        #expect(StoragePresentation.methodText(StorageCleanOutcome.Method.command) == "Befehl")
    }

    @Test func statusTexts() {
        #expect(StoragePresentation.statusText(.needsFullDiskAccess) == "Festplattenvollzugriff nötig")
        #expect(StoragePresentation.statusText(.notInstalled) == "Nicht installiert")
        #expect(StoragePresentation.statusText(.available) == nil)
    }

    @Test func summaryWithPartlyUnknownFreedSizeIsMinimum() {
        let outcomes = [removed("/a", freed: 2_000), removed("docker", freed: nil)]
        #expect(StoragePresentation.summary(outcomes) == "mindestens \(AppTexts.formattedSize(2_000)) freigegeben")
    }

    @Test func summaryWithoutKnownFreedSizeCountsRemovedEntries() {
        let outcomes = [removed("docker", freed: nil), removed("simctl", freed: nil),
                        StorageCleanOutcome(categoryID: "c", target: "/c", method: .trash, freedBytes: nil,
                                            result: .failed("y"))]
        #expect(StoragePresentation.summary(outcomes) == "2 aufgeräumt, freigegebene Größe unbekannt, 1 fehlgeschlagen")
    }

    @Test func summaryWithoutRemovedEntriesClaimsNoFreedSpace() {
        let outcomes = [StorageCleanOutcome(categoryID: "c", target: "/b", method: .trash, freedBytes: nil,
                                            result: .skipped("x"))]
        #expect(StoragePresentation.summary(outcomes) == "Nichts aufgeräumt, 1 übersprungen")
    }

    @Test func confirmButtonNamesOnlyTheKnownPart() {
        let complete = report("a", .low, sizes: [("/a", .bytes(2_000), .delete)])
        #expect(StoragePresentation.confirmation(reports: [complete], selection: ["/a"]).confirmTitle
                == "\(AppTexts.formattedSize(2_000)) freigeben")

        let partial = report("b", .low, sizes: [("/b", .bytes(2_000), .delete), ("/c", .unreadable, .delete),
                                                 ("/d", .unknown, .delete)])
        let confirmation = StoragePresentation.confirmation(reports: [partial], selection: ["/b", "/c", "/d"])
        #expect(confirmation.confirmTitle == "mindestens \(AppTexts.formattedSize(2_000)) freigeben")
        #expect(confirmation.message?.contains("nicht lesbar") == true)
    }

    @Test func confirmButtonWithoutKnownSizeIsPlain() {
        let unknown = report("a", .low, sizes: [("/a", .unknown, .delete), ("/b", .unreadable, .delete)])
        #expect(StoragePresentation.confirmation(reports: [unknown], selection: ["/a", "/b"]).confirmTitle == "Aufräumen")
    }

    @Test func commandSelectionAddsCategorySummaryAndStrongerNote() {
        let docker = report("Docker", .medium, summary: "Gestoppte Container samt ungenutzten Images.",
                            sizes: [("docker", .unknown, dockerPrune)])
        let caches = report("caches", .low, summary: "Programm-Caches.", sizes: [("/a", .bytes(10), .delete)])
        let confirmation = StoragePresentation.confirmation(reports: [docker, caches], selection: ["docker", "/a"])
        let lines = confirmation.message?.components(separatedBy: "\n")
        #expect(lines?.first == "Docker: Befehl: /usr/local/bin/docker system prune -f – Größe unbekannt")
        #expect(lines?.dropFirst().first == "Gestoppte Container samt ungenutzten Images.")
        #expect(lines?.contains("Programm-Caches.") == false)
        #expect(confirmation.note == "Befehle und endgültiges Löschen lassen sich nicht rückgängig machen.")
        #expect(confirmation.confirmTitle == "\(AppTexts.formattedSize(10)) freigeben")
    }

    @Test func trashOnlyConfirmButtonDoesNotPromiseFreedSpace() {
        let complete = report("a", .medium, sizes: [("/a", .bytes(2_000), .trash)])
        #expect(StoragePresentation.confirmation(reports: [complete], selection: ["/a"]).confirmTitle
                == "\(AppTexts.formattedSize(2_000)) in den Papierkorb legen")

        let partial = report("b", .medium, sizes: [("/b", .bytes(2_000), .trash), ("/c", .unreadable, .trash)])
        #expect(StoragePresentation.confirmation(reports: [partial], selection: ["/b", "/c"]).confirmTitle
                == "mindestens \(AppTexts.formattedSize(2_000)) in den Papierkorb legen")

        let unknown = report("c", .medium, sizes: [("/d", .unknown, .trash)])
        #expect(StoragePresentation.confirmation(reports: [unknown], selection: ["/d"]).confirmTitle
                == "In den Papierkorb legen")
    }

    @Test func mixedConfirmButtonNamesBothParts() {
        let mixed = report("a", .medium, sizes: [("/a", .bytes(2_000), .delete), ("/b", .bytes(9_000), .trash)])
        #expect(StoragePresentation.confirmation(reports: [mixed], selection: ["/a", "/b"]).confirmTitle
                == "\(AppTexts.formattedSize(2_000)) freigeben, \(AppTexts.formattedSize(9_000)) in den Papierkorb legen")

        let partial = report("b", .medium, sizes: [("/c", .bytes(2_000), .delete), ("/d", .unknown, .delete),
                                                    ("/e", .bytes(9_000), .trash), ("/f", .unreadable, .trash)])
        #expect(StoragePresentation.confirmation(reports: [partial], selection: ["/c", "/d", "/e", "/f"]).confirmTitle
                == "mindestens \(AppTexts.formattedSize(2_000)) freigeben, "
                + "mindestens \(AppTexts.formattedSize(9_000)) in den Papierkorb legen")
    }

    @Test func mixedConfirmButtonOmitsThePartWithoutKnownSize() {
        let unknownCommand = report("a", .medium, sizes: [("/c", .bytes(9_000), .trash), ("docker", .unknown, dockerPrune)])
        #expect(StoragePresentation.confirmation(reports: [unknownCommand], selection: ["/c", "docker"]).confirmTitle
                == "\(AppTexts.formattedSize(9_000)) in den Papierkorb legen")

        let unknownTrash = report("b", .medium, sizes: [("/d", .unknown, .trash), ("/e", .bytes(2_000), .delete)])
        #expect(StoragePresentation.confirmation(reports: [unknownTrash], selection: ["/d", "/e"]).confirmTitle
                == "\(AppTexts.formattedSize(2_000)) freigeben")

        let neither = report("c", .medium, sizes: [("/f", .unknown, .trash), ("docker", .unknown, dockerPrune)])
        #expect(StoragePresentation.confirmation(reports: [neither], selection: ["/f", "docker"]).confirmTitle
                == "Aufräumen")
    }

    @Test func commandOnlySelectionNeedsNoDeleteNote() {
        let docker = report("Docker", .medium, sizes: [("docker", .unknown, dockerPrune)])
        let trash = report("logs", .medium, sizes: [("/a", .bytes(10), .trash)])
        #expect(StoragePresentation.confirmation(reports: [docker], selection: ["docker"]).note
                == "Befehle lassen sich nicht rückgängig machen.")
        #expect(StoragePresentation.confirmation(reports: [docker, trash], selection: ["docker", "/a"]).note
                == "Befehle lassen sich nicht rückgängig machen.")
    }

    @Test func summarySeparatesTrashedFromFreedBytes() {
        let outcomes = [removed("/a", freed: 2_000), removed("/b", freed: 9_000, method: .trash)]
        #expect(StoragePresentation.summary(outcomes)
                == "\(AppTexts.formattedSize(2_000)) freigegeben, "
                + "\(AppTexts.formattedSize(9_000)) in den Papierkorb gelegt (frei nach dem Leeren)")
    }

    @Test func summaryOfTrashOnlyClaimsNoFreedBytes() {
        let outcomes = [removed("/b", freed: 9_000, method: .trash),
                        StorageCleanOutcome(categoryID: "c", target: "/c", method: .trash, freedBytes: nil,
                                            result: .skipped("x"))]
        #expect(StoragePresentation.summary(outcomes)
                == "\(AppTexts.formattedSize(9_000)) in den Papierkorb gelegt (frei nach dem Leeren), 1 übersprungen")
    }

    @Test func summaryOfTrashWithPartlyOrFullyUnknownSizeIsHonest() {
        let partial = [removed("/a", freed: 9_000, method: .trash), removed("/b", freed: nil, method: .trash)]
        #expect(StoragePresentation.summary(partial)
                == "mindestens \(AppTexts.formattedSize(9_000)) in den Papierkorb gelegt (frei nach dem Leeren)")

        let unknown = [removed("/c", freed: nil, method: .trash), removed("docker", freed: nil, method: .command)]
        #expect(StoragePresentation.summary(unknown)
                == "1 aufgeräumt, freigegebene Größe unbekannt, 1 in den Papierkorb gelegt (Größe unbekannt)")
    }

    @Test func commandStockNeverCountsAsFreedSpace() {
        let thirtyGB: Int64 = 30_000_000_000
        let uv = report("uv", .low, summary: "Entfernt nur ungenutzte Einträge.", sizes: [("uv", .bytes(thirtyGB), dockerPrune)])
        let only = StoragePresentation.confirmation(reports: [uv], selection: ["uv"])
        #expect(only.confirmTitle == "Aufräumen")
        #expect(only.message?.contains("Bestand \(AppTexts.formattedSize(thirtyGB))") == true)
        #expect(only.message?.contains("freigegeben wird nur Ungenutztes") == true)

        let caches = report("caches", .low, sizes: [("/a", .bytes(1_000_000_000), .delete)])
        let mixed = StoragePresentation.confirmation(reports: [caches, uv], selection: ["/a", "uv"])
        #expect(mixed.confirmTitle == "\(AppTexts.formattedSize(1_000_000_000)) freigeben")
        #expect(mixed.message?.contains("caches: endgültig löschen – \(AppTexts.formattedSize(1_000_000_000))") == true)

        let trash = report("logs", .medium, sizes: [("/b", .bytes(5_000_000_000), .trash)])
        #expect(StoragePresentation.confirmation(reports: [trash, uv], selection: ["/b", "uv"]).confirmTitle
                == "\(AppTexts.formattedSize(5_000_000_000)) in den Papierkorb legen")
    }

    @Test func runtimeDeletionShowsTheRuntimeSizeNotAStock() {
        let spec = CommandSpec.tool("/usr/bin/xcrun", ["simctl", "runtime", "delete", "7DF402E9-FCB8-4316-9E68-99A206D93E7F"])
        let item = StorageItem(id: "runtime:7DF4", title: "iOS 27.0", path: nil, size: .bytes(8_000_000_000),
                               removal: .command(spec), isPreselected: false, commandRemovesItem: true)
        let report = StorageCategoryReport(
            category: StorageCategory(id: "simulatorRuntimes", title: "Simulator-Laufzeiten", summary: "Fährt Simulatoren herunter.",
                                      risk: .medium, roots: []), status: .available, items: [item])
        let confirmation = StoragePresentation.confirmation(reports: [report], selection: [item.id])
        #expect(confirmation.message == "Simulator-Laufzeiten: Befehl: \(spec.commandLine) – \(AppTexts.formattedSize(8_000_000_000))"
                + "\nFährt Simulatoren herunter.")
        #expect(confirmation.confirmTitle == "Aufräumen")
        #expect(confirmation.note == "Befehle lassen sich nicht rückgängig machen.")
    }

    @Test func coverageNoteCountsUnreadableFoldersOnce() {
        let unreadable = StorageCategoryReport(
            category: StorageCategory(id: "a", title: "a", summary: "", risk: .low, roots: ["/x"]), status: .needsFullDiskAccess,
            items: [], unreadablePaths: ["/x"])
        let partly = report("b", .reportOnly, sizes: [("/y", .unreadable, .none), ("/z", .bytes(1), .none)])
        #expect(StoragePresentation.uncoveredPaths([unreadable, partly, unreadable]) == ["/x", "/y"])
        #expect(StoragePresentation.coverageNote([unreadable, partly])
                == "Nicht erfassbar: 2 Ordner – ohne Leserecht fehlen ihre Größen in den Summen.")
        #expect(StoragePresentation.coverageNote([unreadable]) == "Nicht erfassbar: 1 Ordner – ohne Leserecht fehlen ihre Größen in den Summen.")
        #expect(StoragePresentation.coverageNote([report("c", .low, [("/c", 1, .delete)])]) == nil)
    }

    /// #229: Neben gefundenen Agenten-Arbeitsordnern der Hinweis, dass ein Neustart `/private/tmp` leert.
    @Test func restartNoteAppearsOnlyWithAgentWorkdirs() {
        let workdirs = report(AgentWorkdirsProvider.categoryID, .low, [("/private/tmp/claude-501/p/s", 1, .trash)])
        #expect(StoragePresentation.restartNote([workdirs])
                == "Ein Neustart des Mac leert /private/tmp und damit auch die Arbeitsordner von Claude Code.")
        #expect(StoragePresentation.restartNote([report(AgentWorkdirsProvider.categoryID, .low, [])]) == nil)
        #expect(StoragePresentation.restartNote([report("caches", .low, [("/c", 1, .delete)])]) == nil)
    }

    @Test func unassignedNoteSubtractsCountedCategoriesFromUsedSpace() {
        let volume = VolumeUsage(totalBytes: 1_000_000_000_000, availableBytes: 100_000_000_000)
        let counted = [report("a", .low, [("/a", 200_000_000_000, .delete)])]
        let rest = "Apps, Dokumente, System sowie lokale Snapshots, Spotlight-Index und Dateiversionen (.DocumentRevisions-V100)."
        #expect(StoragePresentation.unassignedNote(counted, volume: volume)
                == "Keiner Kategorie zugeordnet: \(AppTexts.formattedSize(700_000_000_000)) von "
                + "\(AppTexts.formattedSize(900_000_000_000)) belegt – " + rest)
        let partial = counted + [report("b", .reportOnly, sizes: [("/b", .unknown, .none)])]
        #expect(StoragePresentation.unassignedNote(partial, volume: volume)?.hasPrefix("Keiner Kategorie zugeordnet: höchstens ") == true)
        let failed = counted + [StorageCategoryReport(
            category: StorageCategory(id: "f", title: "f", summary: "", risk: .medium, roots: []), status: .failed("x"), items: [])]
        #expect(StoragePresentation.unassignedNote(failed, volume: volume)?.hasPrefix("Keiner Kategorie zugeordnet: höchstens ") == true)
        let tooMuch = [report("a", .low, [("/a", 950_000_000_000, .delete)])]
        #expect(StoragePresentation.unassignedNote(tooMuch, volume: volume) == nil)
    }
}
