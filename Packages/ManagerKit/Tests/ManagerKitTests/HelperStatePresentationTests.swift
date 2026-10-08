import Testing
import ManagerKit

@Suite struct HelperStatePresentationTests {
    @Test(arguments: [
        (HelperState.ready, "Bereit", PresentationTone.positive, HelperStatePresentation.Action?.none),
        (.notInstalled, "Nicht installiert", .critical, .install),
        (.awaitingApproval, "Wartet auf Genehmigung unter „Anmeldeobjekte & Erweiterungen“", .warning, .approve),
        (.outdated(installed: 1, expected: 2), "Veraltet (Protokollversion 1, erwartet 2)", .warning, .reinstall),
        (.unreachable("Zeitüberschreitung"), "Nicht erreichbar: Zeitüberschreitung", .critical, .reinstall),
        (.missingFromBundle, "Fehlt im App-Bundle", .critical, nil),
        (.requiresAdministrator, "Administratorrechte erforderlich", .critical, nil),
    ])
    func presentsState(
        state: HelperState, text: String, tone: PresentationTone, action: HelperStatePresentation.Action?
    ) {
        let presentation = HelperStatePresentation(state)
        #expect(presentation.text == text)
        #expect(presentation.tone == tone)
        #expect(presentation.action == action)
        #expect(presentation.systemImage == tone.systemImage)
    }

    @Test func actionTitlesAreGerman() {
        #expect(HelperStatePresentation.Action.install.title == "Installieren")
        #expect(HelperStatePresentation.Action.approve.title == "Genehmigen")
        #expect(HelperStatePresentation.Action.reinstall.title == "Neu installieren")
    }

    @Test func tonesHaveDistinctSymbols() {
        let symbols = PresentationTone.allCases.map(\.systemImage)
        #expect(Set(symbols).count == PresentationTone.allCases.count)
    }
}
