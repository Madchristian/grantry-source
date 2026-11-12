import Foundation
import Testing
@testable import ManagerKit

/// Zustandszeile und Stand der Suche in Aufräumen › App-Reste (LB-4.2, #548; Spec 2026-11-10 § 11.4 und Korrektur 3):
/// vor dem ersten Ergebnis kein Urteil (Schildform offen, keine Chips), danach Reste, offene Funde oder „Ruhig“ – ohne
/// Entwarnung bei unvollständiger Suche.
@Suite struct LeftoverVerdictTests {
    private let home = "/u"
    private let caches = LeftoverCandidate(path: "/u/Library/Caches/com.example.tool", kind: .caches, confidence: .safe,
                                           size: .bytes(1_000))
    private let support = LeftoverCandidate(path: "/u/Library/Application Support/Tool", kind: .applicationSupport,
                                            confidence: .uncertain, size: .bytes(2_000))
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func presentation(groups: [OrphanGroup], items: [AutostartItem] = [], grants: [PermissionGrant] = [],
                              unreadable: [String] = [], coverage: OrphanScanCoverage = .complete) -> CleanupPresentation {
        CleanupPresentation(result: OrphanScanResult(groups: groups, autostartItems: items, grants: grants,
                                                     unreadableLocations: unreadable, coverage: coverage), home: home,
                            searchedAt: time)
    }

    private var searchTime: String { time.formatted(date: .omitted, time: .shortened) }

    @Test func beforeTheFirstSearchThereIsNoVerdict() {
        let verdict = LeftoverVerdict(phase: .idle, presentation: nil, extensionLeftovers: 2)
        #expect(verdict.title == "Noch nicht gesucht")
        #expect(verdict.shield == .open)
        #expect(verdict.items.isEmpty)
        #expect(verdict.facts == "sucht nur auf Knopfdruck")
    }

    @Test func whileSearchingTheShieldStaysOpenAndNamesExtensions() {
        let verdict = LeftoverVerdict(phase: .searching, presentation: nil, extensionLeftovers: 1)
        #expect(verdict.title == "Suche läuft")
        #expect(verdict.shield == .open)
        #expect(verdict.items.isEmpty)
        #expect(verdict.facts == "1 Erweiterung ohne App")
        let cancelled = LeftoverVerdict(phase: .cancelled, presentation: nil, extensionLeftovers: 0)
        #expect(cancelled.title == "Suche abgebrochen")
        #expect(cancelled.shield == .open)
        #expect(cancelled.facts == "")
    }

    @Test func leftoversOfDeletedAppsAreAFinding() {
        let item = TestData.item(programPresence: .missing)
        let result = presentation(groups: [OrphanGroup(identifier: "com.example.tool", candidates: [caches, support]),
                                           OrphanGroup(identifier: "com.example.other", candidates: [caches])],
                                  items: [item])
        let verdict = LeftoverVerdict(phase: .finished, presentation: result, extensionLeftovers: 1)
        #expect(verdict.title == "Reste von 2 Apps")
        #expect(verdict.shield == .finding)
        #expect(verdict.items == [SystemVerdict.Item(text: "1 Erweiterung", tone: .warning),
                                  SystemVerdict.Item(text: "1 unsicher", tone: .neutral)])
        #expect(verdict.facts == "4 Funde · \(AppTexts.formattedSize(4_000)) · Suche \(searchTime)")
    }

    @Test func onlyOrphanEntriesCountAsOpenFindings() {
        let item = TestData.item(programPresence: .missing)
        let verdict = LeftoverVerdict(phase: .finished, presentation: presentation(groups: [], items: [item]),
                                      extensionLeftovers: 0)
        #expect(verdict.title == "1 Fund offen")
        #expect(verdict.shield == .finding)
        #expect(verdict.facts == "1 Fund · Suche \(searchTime)")
    }

    @Test func nothingFoundIsCalm() {
        let verdict = LeftoverVerdict(phase: .finished, presentation: presentation(groups: []), extensionLeftovers: 0)
        #expect(verdict.title == "Ruhig")
        #expect(verdict.shield == .calm)
        #expect(verdict.items.isEmpty)
        #expect(verdict.facts == "keine Reste · Suche \(searchTime)")
    }

    /// Ohne vollständige Suche keine Entwarnung: offene Schildform und ein Chip, der es sagt.
    @Test func incompleteSearchWithoutFindingsIsNotCalm() {
        let verdict = LeftoverVerdict(phase: .finished,
                                      presentation: presentation(groups: [], coverage: .unavailable("kein Inventar")),
                                      extensionLeftovers: 0)
        #expect(verdict.title == "Nicht vollständig geprüft")
        #expect(verdict.shield == .open)
        #expect(verdict.items == [SystemVerdict.Item(text: "Suche unvollständig", tone: .neutral)])
        let unreadable = LeftoverVerdict(phase: .finished,
                                         presentation: presentation(groups: [], unreadable: ["/u/Library/Containers"]),
                                         extensionLeftovers: 0)
        #expect(unreadable.title == "Nicht vollständig geprüft")
    }

    // MARK: Stand der Suche

    @Test func standNamesCompletenessAndAge() {
        #expect(LeftoverSearchStand(presentation: presentation(groups: []), isOutdated: false) == .complete)
        #expect(LeftoverSearchStand(presentation: presentation(groups: [], unreadable: ["/x"]), isOutdated: false)
            == .incomplete)
        #expect(LeftoverSearchStand(presentation: presentation(groups: [], coverage: .incomplete("x")), isOutdated: false)
            == .incomplete)
        #expect(LeftoverSearchStand(presentation: presentation(groups: []), isOutdated: true) == .outdated)
    }
}
