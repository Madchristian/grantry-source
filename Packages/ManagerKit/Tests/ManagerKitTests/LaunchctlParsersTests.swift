import Testing
@testable import ManagerKit

@Suite struct LaunchctlParsersTests {
    @Test func parsesDisabledOverrides() {
        let output = """
        \tdisabled services = {
        \t\t"com.bjango.istatmenus.agent" => enabled
        \t\t"com.apple.ManagedClientAgent.enrollagent" => disabled
        \t\t"org.legacy" => true
        \t\t"org.legacy2" => false
        \t}
        """
        #expect(LaunchctlParsers.disabledOverrides(output) == [
            "com.bjango.istatmenus.agent": false,
            "com.apple.ManagedClientAgent.enrollagent": true,
            "org.legacy": true,
            "org.legacy2": false,
        ])
    }

    @Test func parsesLoadedServiceLabels() {
        let output = """
        gui/501 = {
        \ttype = login
        \tservices = {
        \t\t   97811      - \tapplication.com.apple.RemoteDesktop.53958277.53958923
        \t\t     750      - \tcom.apple.syncdefaultsd
        \t\t       0      0 \tcom.apple.DataDetectorsLocalSources
        \t}
        \tunmanaged processes = {
        \t\tnot.a.service
        \t}
        }
        """
        #expect(LaunchctlParsers.loadedLabels(output) == [
            "application.com.apple.RemoteDesktop.53958277.53958923",
            "com.apple.syncdefaultsd",
            "com.apple.DataDetectorsLocalSources",
        ])
    }

    /// Ohne Blockkopf ist das Format unbekannt; ein leeres Ergebnis würde jeden Eintrag umkippen lassen.
    @Test(arguments: ["", "gui/501 = {\n\ttype = login\n}", "\t\"com.example.ok\" => enabled"])
    func outputWithoutBlockHeaderYieldsNil(output: String) {
        #expect(LaunchctlParsers.disabledOverrides(output) == nil)
        #expect(LaunchctlParsers.loadedLabels(output) == nil)
    }

    /// `print-disabled` einer Domain ohne Overrides liefert den Kopf mit leerem Rumpf.
    @Test func emptyBlocksYieldEmptyResults() {
        #expect(LaunchctlParsers.disabledOverrides("\n\tdisabled services = {\n\t}\n") == [:])
        #expect(LaunchctlParsers.loadedLabels("gui/501 = {\n\tservices = {\n\t}\n}") == [])
    }

    /// `launchctl print` enthält auch einen `disabled services`-Block; er zählt nicht als `services`.
    @Test func disabledServicesBlockIsNotMistakenForServices() {
        let output = "gui/501 = {\n\tdisabled services = {\n\t\t\"x\" => disabled\n\t}\n}"
        #expect(LaunchctlParsers.loadedLabels(output) == nil)
    }

    /// Nur Zeilen im Block `disabled services` zählen.
    @Test func overridesOutsideBlockAreIgnored() {
        let output = "\t\"com.before\" => enabled\n\tdisabled services = {\n\t\t\"com.inside\" => disabled\n\t}\n\t\"com.after\" => enabled"
        #expect(LaunchctlParsers.disabledOverrides(output) == ["com.inside": true])
    }

    @Test func unknownValueAfterArrowIsSkipped() {
        let output = """
        \tdisabled services = {
        \t\t"com.example.unknown" => maybe
        \t\t"com.example.ok" => enabled
        \t}
        """
        #expect(LaunchctlParsers.disabledOverrides(output) == ["com.example.ok": false])
    }

    /// Labels im `unmanaged processes`-Block (z. B. `Discord Helper.79735`) enthalten Leerzeichen; die
    /// dritte Spalte darf deshalb nicht an jedem Whitespace weiter aufgesplittet werden.
    @Test func labelsContainingSpacesSurviveSplitting() {
        let output = """
        gui/501 = {
        \tservices = {
        \t\t     750      - \tDiscord Helper.79735
        \t}
        }
        """
        #expect(LaunchctlParsers.loadedLabels(output) == ["Discord Helper.79735"])
    }

    // Der Dienst-Pfad aus `launchctl print <domain>/<label>` wird in GrantryShared ausgewertet
    // (`LaunchdServiceBinding`, Tests dort).
}
