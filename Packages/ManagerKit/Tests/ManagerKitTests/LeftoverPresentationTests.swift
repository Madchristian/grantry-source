import Foundation
import Testing
@testable import ManagerKit

@Suite struct LeftoverPresentationTests {
    private let home = "/u"
    private let bundle = LeftoverCandidate(path: "/Applications/Tool.app", kind: .appBundle, confidence: .safe, size: .bytes(4_000))
    private let caches = LeftoverCandidate(path: "/u/Library/Caches/com.example.tool", kind: .caches, confidence: .safe,
                                           size: .unreadable)
    private let support = LeftoverCandidate(path: "/u/Library/Application Support/Tool", kind: .applicationSupport,
                                            confidence: .uncertain, size: .bytes(1_000), note: "Ordner nach App-Name")
    private let container = LeftoverCandidate(path: "/u/Library/Containers/com.example.tool", kind: .container,
                                              confidence: .safe, size: .unknown)
    private var candidates: [LeftoverCandidate] { [bundle, caches, support, container] }

    // MARK: Abschnitte und Zeilen

    @Test func sectionsFollowTheKindOrder() {
        let sections = LeftoverSection.sections(candidates, home: home)
        #expect(sections.map(\.kind) == [.appBundle, .container, .applicationSupport, .caches])
        #expect(sections.map(\.title) == ["App", "Container", "Programmdaten", "Caches"])
        #expect(sections[0].sizeText == AppTexts.formattedSize(4_000))
        #expect(sections[3].sizeText == "Größe nicht lesbar")
    }

    @Test func rowsShowConfidenceAsTextAndAbbreviatePaths() {
        let rows = LeftoverSection.sections(candidates, home: home).flatMap(\.rows)
        let supportRow = rows.first { $0.id == support.path }!
        #expect(supportRow.pathText == "~/Library/Application Support/Tool")
        #expect(supportRow.confidenceText == "Zuordnung unsicher")
        #expect(!supportRow.isPreselected)
        #expect(supportRow.note == "Ordner nach App-Name")
        #expect(supportRow.sizeText == AppTexts.formattedSize(1_000))
        #expect(supportRow.accessibilityLabel
            == "~/Library/Application Support/Tool, Zuordnung unsicher, \(AppTexts.formattedSize(1_000)), Hinweis: Ordner nach App-Name")
        let cachesRow = rows.first { $0.id == caches.path }!
        #expect(cachesRow.confidenceText == "Zuordnung sicher")
        #expect(cachesRow.isPreselected)
        #expect(cachesRow.sizeText == "Größe nicht lesbar")
        #expect(rows.first { $0.id == container.path }!.sizeText == "Größe unbekannt")
    }

    @Test func forcedUncertaintyOverridesSafeCandidates() {
        let rows = LeftoverSection.sections(candidates, treatingAllAsUncertain: true, home: home).flatMap(\.rows)
        #expect(rows.allSatisfy { !$0.isPreselected && $0.confidenceText == "Zuordnung unsicher" })
    }

    // MARK: Auswahl

    @Test func selectionStartsWithSafeCandidatesGrantsAndItems() {
        let grant = TestData.grant(), item = TestData.item()
        var selection = RemovalSelection(candidates: candidates, grants: [grant], autostartItems: [item])
        #expect(selection.selected == Set([bundle.path, caches.path, container.path, grant.id, item.id]))
        selection.set(support.path, selected: true)
        selection.set(grant.id, selected: false)
        #expect(selection.contains(support.path))
        #expect(!selection.contains(grant.id))
        selection.toggle(support.path)
        #expect(!selection.contains(support.path))
    }

    // MARK: Entfernen einer App

    @Test func reviewPreselectsSafeFilesAndAvailableLinks() {
        let app = TestData.installedApp("Tool", bundleID: "com.example.tool")
        let grant = TestData.grant(client: app.identity)
        let item = TestData.item(owner: app.identity)
        let review = RemovalReview(
            leftovers: LeftoverScanResult(candidates: candidates, unreadableLocations: ["/u/Library/Containers"]),
            links: AppLinks(grants: [grant], autostartItems: [item]), home: home
        )
        #expect(review.sections.map(\.kind) == [.appBundle, .container, .applicationSupport, .caches])
        #expect(review.initialSelection.selected == Set([bundle.path, caches.path, container.path, grant.id, item.id]))
        #expect(review.unreadableNote == "Nicht durchsucht (keine Leserechte): ~/Library/Containers")
    }

    @Test func reviewDoesNotPreselectReadOnlyLinks() {
        let appleGrant = TestData.grant(client: AppIdentity(
            bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", displayName: "Terminal",
            signing: SigningInfo(kind: .apple), presence: .present
        ))
        let review = RemovalReview(leftovers: LeftoverScanResult(candidates: [bundle]),
                                   links: AppLinks(grants: [appleGrant], autostartItems: []), home: home)
        #expect(review.initialSelection.selected == [bundle.path])
        #expect(review.grants == [appleGrant])
        #expect(review.unreadableNote == nil)
    }

    @Test func summaryNamesCountsAndMinimumSize() {
        let grant = TestData.grant()
        let review = RemovalReview(leftovers: LeftoverScanResult(candidates: candidates),
                                   links: AppLinks(grants: [grant], autostartItems: []), home: home)
        var selection = review.initialSelection
        #expect(review.summary(for: selection)
            == "Ausgewählt: 3 Objekte (mindestens \(AppTexts.formattedSize(4_000)), 1 Größe nicht lesbar), 1 Berechtigung")
        selection.set(caches.path, selected: false)
        selection.set(container.path, selected: false)
        selection.set(grant.id, selected: false)
        #expect(review.summary(for: selection) == "Ausgewählt: 1 Objekt (\(AppTexts.formattedSize(4_000)))")
        selection.set(bundle.path, selected: false)
        #expect(review.summary(for: selection) == "Nichts ausgewählt")
    }

    // MARK: Aufräumen

    private func orphanResult(coverage: OrphanScanCoverage, items: [AutostartItem] = [], grants: [PermissionGrant] = [])
        -> OrphanScanResult {
        OrphanScanResult(
            groups: [OrphanGroup(identifier: "com.example.tool", candidates: [caches, support, container])],
            autostartItems: items, grants: grants, unreadableLocations: [], coverage: coverage
        )
    }

    @Test func cleanupGroupsWithCompleteCoverage() {
        let item = TestData.item(programPresence: .missing)
        let cleanup = CleanupPresentation(result: orphanResult(coverage: .complete, items: [item]), home: home)
        #expect(cleanup.coverageNote == nil)
        #expect(cleanup.groups.map(\.identifier) == ["com.example.tool"])
        #expect(cleanup.groups[0].sections.map(\.kind) == [.container, .applicationSupport, .caches])
        #expect(cleanup.groups[0].isUncertain)
        #expect(cleanup.groups[0].sizeText == "mindestens \(AppTexts.formattedSize(1_000)), 1 Größe nicht lesbar")
        #expect(cleanup.initialSelection.selected == Set([caches.path, container.path, item.id]))
        #expect(!cleanup.isEmpty)
    }

    @Test func cleanupIncompleteCoverageMakesEverythingUncertain() {
        let cleanup = CleanupPresentation(result: orphanResult(coverage: .incomplete("App-Inventar unvollständig: x")), home: home)
        #expect(cleanup.coverageNote
            == "App-Inventar unvollständig: x – die Zuordnung aller Funde ist unsicher, nichts ist vorausgewählt.")
        #expect(cleanup.groups.flatMap(\.sections).flatMap(\.rows).allSatisfy { !$0.isPreselected })
        #expect(cleanup.initialSelection.selected.isEmpty)
    }

    @Test func cleanupUnavailableCoverageShowsNoGroups() {
        let cleanup = CleanupPresentation(result: orphanResult(coverage: .unavailable("App-Inventar liegt nicht vor")), home: home)
        #expect(cleanup.groups.isEmpty)
        #expect(cleanup.coverageNote == "Reste gelöschter Apps lassen sich nicht sicher bestimmen: App-Inventar liegt nicht vor")
        #expect(cleanup.initialSelection.selected.isEmpty)
    }

    @Test func cleanupListsOrphanGrantsOnlyAsHint() {
        let grant = TestData.grant(client: TestData.app("com.gone", presence: .missing))
        let cleanup = CleanupPresentation(result: OrphanScanResult(groups: [], autostartItems: [], grants: [grant]), home: home)
        #expect(cleanup.grants == [grant])
        #expect(cleanup.grantsNote != nil)
        #expect(cleanup.initialSelection.selected.isEmpty)
        #expect(!cleanup.isEmpty)
        #expect(CleanupPresentation(result: .empty, home: home).isEmpty)
    }

    @Test func cleanupGroupsOrphanGrantsByServiceName() {
        let gone = TestData.app("com.gone", presence: .missing)
        let screen = TestData.grant("kTCCServiceScreenCapture", client: gone)
        let accessibility = TestData.grant("kTCCServiceAccessibility", client: gone)
        let cleanup = CleanupPresentation(result: OrphanScanResult(groups: [], autostartItems: [], grants: [screen, accessibility]), home: home)
        #expect(cleanup.grantServices.map(\.serviceName) == ["Bedienungshilfen", "Bildschirmaufnahme"])
        #expect(cleanup.grantServices.map(\.grants) == [[accessibility], [screen]])
    }

    @Test func kindTitlesAreGerman() {
        #expect(LeftoverKind.allCases.map(\.displayName) == [
            "App", "Container", "Gruppen-Container", "Programmdaten", "Caches", "Einstellungen", "Fensterzustand",
            "Web-Speicher", "WebKit-Daten", "Protokolle", "App-Skripte",
        ])
    }
}
