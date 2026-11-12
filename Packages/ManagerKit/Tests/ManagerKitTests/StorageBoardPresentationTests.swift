import Foundation
import Testing
@testable import ManagerKit

/// Texte des Speichers im Lagebild (LB-4.3, #549): Zustandszeile, Spur je Kategorie, Umfang der Auswahl und Ergebnis.
@Suite struct StorageBoardPresentationTests {
    private func report(_ id: String, status: StorageCategoryStatus = .available, unreadable: [String] = [],
                        _ items: [(String, FileSize, RemovalMethod)]) -> StorageCategoryReport {
        StorageCategoryReport(
            category: StorageCategory(id: id, title: id, summary: "", risk: .low, roots: []), status: status,
            items: items.map { StorageItem(id: $0.0, title: $0.0, path: $0.0, size: $0.1, removal: $0.2,
                                           isPreselected: true) },
            unreadablePaths: unreadable)
    }

    private func outcome(_ result: StorageCleanOutcome.Result,
                         method: StorageCleanOutcome.Method = .delete) -> StorageCleanOutcome {
        StorageCleanOutcome(categoryID: "c", target: "/a", method: method, freedBytes: nil, result: result)
    }

    @Test func cleanableTextSumsAllCategories() {
        let reports = [report("a", [("/a", .bytes(3_000_000_000), .delete)]),
                       report("b", [("/b", .bytes(1_000_000_000), .trash)])]
        #expect(StoragePresentation.cleanableText(reports) == "\(AppTexts.formattedSize(4_000_000_000)) aufräumbar")
    }

    @Test func cleanableTextSaysMinimumWithUnknownSizes() {
        let reports = [report("a", [("/a", .bytes(2_000), .delete), ("/b", .unknown, .delete)])]
        #expect(StoragePresentation.cleanableText(reports)
                == "mindestens \(AppTexts.formattedSize(2_000)) aufräumbar")
    }

    @Test func shareIsPartOfKnownTotalAndNilWithoutSize() {
        let big = report("a", [("/a", .bytes(3_000), .delete)])
        let small = report("b", [("/b", .bytes(1_000), .delete)])
        let empty = report("c", status: .needsFullDiskAccess, [])
        let reports = [big, small, empty]
        #expect(StoragePresentation.share(of: big, in: reports) == 0.75)
        #expect(StoragePresentation.share(of: small, in: reports) == 0.25)
        #expect(StoragePresentation.share(of: empty, in: reports) == nil)
    }

    @Test func selectionTextNamesCountAndSizeOfSelectableItems() {
        let reports = [report("a", [("/a", .bytes(2_000), .delete), ("/b", .bytes(1_000), .none)])]
        #expect(StoragePresentation.selectionText(reports: reports, selection: []) == "Nichts ausgewählt")
        #expect(StoragePresentation.selectionText(reports: reports, selection: ["/b"]) == "Nichts ausgewählt")
        #expect(StoragePresentation.selectionText(reports: reports, selection: ["/a"])
                == "Ausgewählt: 1 Eintrag · \(AppTexts.formattedSize(2_000))")
        let two = [report("a", [("/a", .bytes(2_000), .delete), ("/c", .bytes(1_000), .trash)])]
        #expect(StoragePresentation.selectionText(reports: two, selection: ["/a", "/c"])
                == "Ausgewählt: 2 Einträge · \(AppTexts.formattedSize(3_000))")
    }

    @Test func categoryCountText() {
        #expect(StoragePresentation.categoryCountText(1) == "1 Kategorie")
        #expect(StoragePresentation.categoryCountText(9) == "9 Kategorien")
    }

    @Test func completenessNeedsAllCategoriesAndFolders() {
        #expect(StoragePresentation.isComplete([report("a", [("/a", .bytes(1), .delete)])]))
        #expect(!StoragePresentation.isComplete([report("a", status: .needsFullDiskAccess, [])]))
        #expect(!StoragePresentation.isComplete([report("a", status: .failed("x"), [])]))
        #expect(!StoragePresentation.isComplete([report("a", unreadable: ["/geheim"], [])]))
        #expect(StoragePresentation.isComplete([report("a", status: .notInstalled, [])]))
    }

    @Test func statusToneMarksMissingAccessAndErrors() {
        #expect(StoragePresentation.statusTone(.available) == nil)
        #expect(StoragePresentation.statusTone(.notInstalled) == .neutral)
        #expect(StoragePresentation.statusTone(.needsFullDiskAccess) == .warning)
        #expect(StoragePresentation.statusTone(.failed("x")) == .critical)
    }

    @Test func outcomeTitleCountsDoneEntries() {
        #expect(StoragePresentation.outcomeTitle([outcome(.removed)]) == "1 Eintrag aufgeräumt")
        #expect(StoragePresentation.outcomeTitle([outcome(.removed), outcome(.removed)]) == "2 Einträge aufgeräumt")
        #expect(StoragePresentation.outcomeTitle([outcome(.removed), outcome(.skipped("x"))])
                == "1 von 2 Einträgen aufgeräumt")
        #expect(StoragePresentation.outcomeTitle([outcome(.removed, method: .timeMachineExclude)])
                == "Time Machine geändert: 1 von 1")
    }

    @Test func outcomeToneIsPositiveOnlyWithoutSkippedOrFailed() {
        #expect(StoragePresentation.outcomeTone([outcome(.removed)]) == .positive)
        #expect(StoragePresentation.outcomeTone([outcome(.removed), outcome(.skipped("x"))]) == .warning)
        #expect(StoragePresentation.outcomeTone([outcome(.failed("y"))]) == .critical)
    }

    @Test func outcomeStateAndReasonSplitResultText() {
        #expect(StoragePresentation.outcomeState(outcome(.removed)) == "aufgeräumt")
        #expect(StoragePresentation.outcomeState(outcome(.removed, method: .timeMachineExclude)) == "ausgenommen")
        #expect(StoragePresentation.outcomeState(outcome(.removed, method: .timeMachineInclude)) == "wieder gesichert")
        #expect(StoragePresentation.outcomeState(outcome(.skipped("x"))) == "übersprungen")
        #expect(StoragePresentation.outcomeState(outcome(.failed("y"))) == "fehlgeschlagen")
        #expect(StoragePresentation.outcomeReason(outcome(.skipped("wird benutzt"))) == "wird benutzt")
        #expect(StoragePresentation.outcomeReason(outcome(.removed)) == nil)
        #expect(StoragePresentation.outcomeTone(of: outcome(.removed)) == .positive)
        #expect(StoragePresentation.outcomeTone(of: outcome(.skipped("x"))) == .neutral)
        #expect(StoragePresentation.outcomeTone(of: outcome(.failed("x"))) == .critical)
    }
}
