import Foundation
import Testing
@testable import ManagerKit
import TestSupport

/// Abdeckungslücken (#139) in der Beobachtungsbilanz (#127) und in leeren Änderungslisten: Eine Lücke darf nie als
/// „nichts passiert“ erscheinen. Läuft in temporären Verzeichnissen mit Attrappen-Plists und gestubbtem launchctl.
@Suite struct ObservationCoverageTests {
    private static func scan(_ directory: URL, previous: Snapshot?, at date: Date) async throws -> Snapshot {
        let runner = MockCommandRunner()
        runner.stub("/bin/launchctl print-disabled gui/501", CommandResult(exitCode: 0, stdout: "\n\tdisabled services = {\n\t}\n"))
        runner.stub("/bin/launchctl print gui/501", CommandResult(exitCode: 0, stdout: "gui/501 = {\n\tservices = {\n\t}\n}\n"))
        let source = LaunchdSource(
            directories: [LaunchdDirectory(path: directory.path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")],
            runner: runner, resolver: StubAppResolver()
        )
        return try await ScanCoordinator(sources: [source], now: { date }).scan(previous: previous)
    }

    /// Wird während der Beobachtung eine Plist unlesbar, gibt es kein Ereignis – die Bilanz ist aber unvollständig,
    /// nennt die Einschränkung und gibt keine Entwarnung.
    @Test func plistBrokenDuringObservationIsNoAllClear() async throws {
        try await ScratchDirectory.with(prefix: "observation-gap") { directory in
            let plist = try LaunchdPlistFixture.write(payload: ["Label": "com.example.agent", "Program": "/bin/ls"], in: directory)
            let baseline = try await Self.scan(directory, previous: nil, at: TestData.date)
            try Data("kaputt".utf8).write(to: plist)
            let final = try await Self.scan(directory, previous: baseline, at: TestData.date + 600)

            let balance = ObservationBalance(baseline: baseline, final: final)
            #expect(balance.events.isEmpty)
            #expect(balance.failedSources.isEmpty)
            #expect(balance.limitations.map(\.source) == [.launchd])
            #expect(!balance.isComplete)

            let presentation = ObservationBalancePresentation(
                balance: balance, attribution: ObservationAttribution(observationName: "Test", newApps: [])
            )
            #expect(presentation.isEmpty)
            #expect(presentation.summary == "Keine Änderungen erkannt – Bilanz unvollständig.")
            #expect(presentation.emptyMessage == ObservationTexts.emptyBalanceMessage(isComplete: false))
            #expect(!presentation.emptyMessage.contains("nichts hinzugekommen"))
            #expect(ObservationTexts.limitationsNote(balance.limitations.map(\.message))?.contains(plist.path) == true)
        }
    }

    /// Einschränkungen aus Start und Ende zählen beide, Dubletten einmal; ohne Einschränkungen bleibt die Entwarnung.
    @Test func limitationsOfBothEndsAreMergedWithoutDuplicates() {
        let gap = SourceLimitation(source: .launchd, message: "Plist /x.plist nicht auswertbar")
        let other = SourceLimitation(source: .apps, message: "Signaturprüfung ausgefallen")
        var baseline = TestData.snapshot()
        baseline.sourceLimitations = [gap]
        var final = TestData.snapshot(at: TestData.date + 600)
        final.sourceLimitations = [gap, other]

        #expect(ObservationBalance(baseline: baseline, final: final).limitations == [gap, other])
        #expect(ObservationBalance(baseline: baseline, final: TestData.snapshot()).isComplete == false)

        let complete = ObservationBalance(baseline: TestData.snapshot(), final: TestData.snapshot(at: TestData.date + 600))
        #expect(complete.isComplete)
        let presentation = ObservationBalancePresentation(
            balance: complete, attribution: ObservationAttribution(observationName: "Test", newApps: [])
        )
        #expect(presentation.summary == "Keine Änderungen während der Beobachtung.")
        #expect(presentation.emptyMessage == "Während der Beobachtung ist nichts hinzugekommen, verändert oder verschwunden.")
    }

    /// Ausgefallene Quellen unterdrücken die Entwarnung ebenso; Änderungen bleiben gezählt, mit Vermerk.
    @Test func failedSourcesAndChangesAreMarkedIncomplete() {
        let baseline = TestData.snapshot(items: [TestData.item("com.example.kept")])
        let final = TestData.snapshot(
            items: [TestData.item("com.example.kept"), TestData.item("com.example.new")],
            errors: [SourceError(source: .btm, message: "Helper fehlt")], at: TestData.date + 600
        )
        let presentation = ObservationBalancePresentation(
            balance: ObservationBalance(baseline: baseline, final: final),
            attribution: ObservationAttribution(observationName: "Test", newApps: [])
        )
        #expect(presentation.summary == "1 neu, 0 geändert, 0 entfernt – Bilanz unvollständig")
    }

    /// Leere Änderungslisten (Übersicht, Menüleiste, Verlauf) melden „keine Änderungen“ nur bei vollständiger Abdeckung.
    @Test func emptyChangeListsAreNoAllClearWithGaps() {
        var snapshot = TestData.snapshot()
        #expect(!snapshot.hasIncompleteCoverage)
        #expect(CoverageTexts.noChanges(hasIncompleteCoverage: snapshot.hasIncompleteCoverage) == "Keine Änderungen seit dem ersten Scan.")

        snapshot.sourceLimitations = [SourceLimitation(source: .launchd, message: "Verzeichnis nicht lesbar")]
        #expect(snapshot.hasIncompleteCoverage)
        #expect(CoverageTexts.noChanges(hasIncompleteCoverage: true).contains("nicht alle Quellen"))

        #expect(TestData.snapshot(errors: [SourceError(source: .btm, message: "x")]).hasIncompleteCoverage)
    }
}
