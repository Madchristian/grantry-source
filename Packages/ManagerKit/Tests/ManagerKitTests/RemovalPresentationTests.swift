import Foundation
import Testing
@testable import ManagerKit

@Suite struct RemovalPresentationTests {
    private let home = "/Users/test"
    private let cache = LeftoverCandidate(path: "/Users/test/Library/Caches/com.example.tool", kind: .caches, confidence: .safe,
                                          size: .bytes(2_000_000))
    private let bundle = LeftoverCandidate(path: "/Applications/Tool.app", kind: .appBundle, confidence: .safe,
                                           size: .bytes(8_000_000))

    private func file(_ name: String, size: FileSize) -> LeftoverCandidate {
        LeftoverCandidate(path: "/Users/test/Library/Caches/\(name)", kind: .caches, confidence: .safe, size: size)
    }

    // MARK: Ergebnis

    @Test func everythingDoneIsPositive() {
        let report = RemovalReport(entries: [
            .init(subject: .file(bundle), result: .done), .init(subject: .file(cache), result: .done),
            .init(subject: .grant(TestData.grant()), result: .done),
            .init(subject: .autostartItem(TestData.item()), result: .done),
        ])
        let presentation = ActionOutcomePresentation.removal(report, home: home)
        #expect(presentation.tone == .positive)
        #expect(presentation.text == "In den Papierkorb gelegt: 2 Objekte (\(AppTexts.formattedSize(10_000_000))); "
                + "Berechtigungen zurückgesetzt: 1; Autostart-Einträge entfernt: 1. Wiederherstellen über „Zurücklegen“ im Papierkorb.")
        #expect(presentation.details.isEmpty)
        #expect(presentation.settingsURL == nil)
    }

    /// #97: Ohne aktuellen Scan übersprungene Berechtigungen und Autostart-Einträge nennen den Grund im Bericht.
    @Test func linksSkippedWithoutCurrentScanNameTheReason() {
        let grant = TestData.grant()
        let item = TestData.item("com.example.agent")
        let report = RemovalReport(entries: [
            .init(subject: .file(bundle), result: .done),
            .init(subject: .grant(grant), result: .skipped(OrphanRecheck.unavailableReason)),
            .init(subject: .autostartItem(item), result: .skipped(OrphanRecheck.unavailableReason)),
        ])
        let details = ActionOutcomePresentation.removal(report, home: home).details
        #expect(details == [
            "\(RemovalReport.Subject.grant(grant).displayName(home: home)): \(OrphanRecheck.unavailableReason)",
            "„com.example.agent“: \(OrphanRecheck.unavailableReason)",
        ])
    }

    @Test func partialResultListsWhatFailedWithTildePaths() {
        let report = RemovalReport(entries: [
            .init(subject: .file(bundle), result: .done),
            .init(subject: .file(cache), result: .failed("Abgebrochen (z. B. Passwortabfrage)")),
            .init(subject: .grant(TestData.grant()), result: .failed("Befehl fehlgeschlagen")),
            .init(subject: .autostartItem(TestData.item("com.example.agent")), result: .doneWithWarning("Kein Beleg")),
        ])
        let presentation = ActionOutcomePresentation.removal(report, home: home)
        #expect(presentation.tone == .warning)
        #expect(presentation.text.hasPrefix("In den Papierkorb gelegt: 1 Objekt (\(AppTexts.formattedSize(8_000_000)))"))
        #expect(presentation.details == [
            "~/Library/Caches/com.example.tool: Abgebrochen (z. B. Passwortabfrage)",
            "Kamera-Berechtigung von us.zoom.xos: Befehl fehlgeschlagen",
            "„com.example.agent“: Kein Beleg",
        ])
    }

    @Test func unreadableSizeIsNamed() {
        let report = RemovalReport(entries: [
            .init(subject: .file(bundle), result: .done), .init(subject: .file(file("x", size: .unreadable)), result: .done),
        ])
        #expect(ActionOutcomePresentation.removal(report, home: home).text.hasPrefix(
            "In den Papierkorb gelegt: 2 Objekte (mindestens \(AppTexts.formattedSize(8_000_000)), 1 Größe nicht lesbar)"
        ))
    }

    @Test func sameReasonForEverythingIsTheText() {
        let plan = RemovalPlan(app: TestData.installedApp("Tool"), grants: [TestData.grant()], autostartItems: [], files: [cache])
        let presentation = ActionOutcomePresentation.removal(.skipping(plan, reason: "Tool läuft noch – bitte zuerst beenden."), home: home)
        #expect(presentation.tone == .critical)
        #expect(presentation.text == "Tool läuft noch – bitte zuerst beenden.")
        #expect(presentation.details.isEmpty)
    }

    @Test func missingAutomationLinksToThePrivacySettings() {
        let plan = RemovalPlan(app: nil, grants: [], autostartItems: [], files: [cache])
        let presentation = ActionOutcomePresentation.removal(
            .skipping(plan, reason: RemovalExecutor.automationDeniedReason, automationDenied: true)
        )
        #expect(presentation.tone == .critical)
        #expect(presentation.text == RemovalExecutor.automationDeniedReason)
        #expect(presentation.settingsURL == TrashPermission.settingsURL)
    }

    @Test func emptyReportSaysNothingWasRemoved() {
        let presentation = ActionOutcomePresentation.removal(RemovalReport(entries: []))
        #expect(presentation.text == "Nichts wurde entfernt.")
        #expect(presentation.details.isEmpty)
    }

    @Test func manyFailuresAreShortened() {
        let files = (0..<12).map { file("f\($0)", size: .unknown) }
        let report = RemovalReport(entries: files.enumerated().map { .init(subject: .file($1), result: .failed("Grund \($0)")) })
        let details = ActionOutcomePresentation.removal(report, home: home).details
        #expect(details.count == ActionOutcomePresentation.maximumDetails + 1)
        #expect(details.last == "… und 4 weitere")
    }

    // MARK: Plan und Bestätigung

    @Test func sizeTexts() {
        func plan(_ sizes: [FileSize]) -> RemovalPlan {
            RemovalPlan(app: nil, grants: [], autostartItems: [],
                        files: sizes.enumerated().map { file("f\($0)", size: $1) })
        }
        #expect(plan([.bytes(1_000)]).sizeText == AppTexts.formattedSize(1_000))
        #expect(plan([.unknown]).sizeText == "Größe unbekannt")
        #expect(plan([.unreadable]).sizeText == "Größe nicht lesbar")
        #expect(plan([.bytes(1_000), .unknown]).sizeText == "mindestens \(AppTexts.formattedSize(1_000))")
        #expect(plan([.bytes(1_000), .unreadable, .unreadable]).sizeText
                == "mindestens \(AppTexts.formattedSize(1_000)), 2 Größen nicht lesbar")
        #expect(plan([.bytes(1_000), .unreadable, .unknown]).knownSize == 1_000)
    }

    @Test func confirmationSummarizesThePlan() {
        let plan = RemovalPlan(app: TestData.installedApp("Tool", bundleID: "com.example.tool"), grants: [TestData.grant()],
                               autostartItems: [TestData.item()], files: [bundle, file("x", size: .unknown)])
        let confirmation = ActionConfirmation.removal(plan)
        #expect(confirmation.title == "„Tool“ entfernen?")
        #expect(confirmation.message == "In den Papierkorb: 2 Objekte (mindestens \(AppTexts.formattedSize(8_000_000)))\n"
                + "Berechtigungen zurücksetzen: 1\nAutostart-Einträge entfernen: 1 (mit Sicherung)")
        #expect(confirmation.note == "Wiederherstellen über „Zurücklegen“ im Papierkorb. Bei geschützten Dateien fragt macOS nach dem Passwort.")
        #expect(confirmation.confirmTitle == "In den Papierkorb legen")
        #expect(confirmation.isDestructive)
    }

    @Test func confirmationNamesLocationsThatWereNotSearched() {
        let plan = RemovalPlan(app: nil, grants: [], autostartItems: [], files: [cache],
                               unreadableLocations: ["/Users/test/Library/Containers", "/Library/Caches"])
        let confirmation = ActionConfirmation.removal(plan, home: home)
        #expect(confirmation.title == "Reste in den Papierkorb legen?")
        #expect(confirmation.note?.hasSuffix("Nicht durchsucht (keine Leserechte): ~/Library/Containers, /Library/Caches") == true)
    }

    @Test func confirmationWithoutFiles() {
        let plan = RemovalPlan(app: nil, grants: [], autostartItems: [TestData.item()], files: [])
        let confirmation = ActionConfirmation.removal(plan)
        #expect(confirmation.title == "Reste entfernen?")
        #expect(confirmation.note == nil)
        #expect(confirmation.confirmTitle == "Entfernen")
    }
}
