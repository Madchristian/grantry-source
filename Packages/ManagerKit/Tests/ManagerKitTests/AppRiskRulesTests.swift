import Foundation
import Security
import Testing
@testable import ManagerKit

@Suite struct AppRiskRulesTests {
    private let teamB = SigningInfo(kind: .developerID, teamID: "TEAMB67890", isNotarized: true)

    // MARK: Team-ID-Wechsel

    @Test func teamIDChangeIsRecordedAndKeptWhileTheNewTeamStays() {
        let previous = TestData.appSnapshot([TestData.installedApp()])
        let changed = TestData.appSnapshot([TestData.installedApp(signing: teamB)], at: TestData.date + TestData.day)
            .carryingForwardAppState(from: previous)
        let change = TeamIDChange(previousTeamID: "TEAMA12345", detectedAt: TestData.date + TestData.day)
        #expect(changed.installedApps.first?.teamIDChange == change)

        let later = TestData.appSnapshot([TestData.installedApp(signing: teamB)], at: TestData.date + 5 * TestData.day)
            .carryingForwardAppState(from: changed)
        #expect(later.installedApps.first?.teamIDChange == change)
        #expect(later.carryingForwardAppState(from: changed) == later, "idempotent")
    }

    @Test func unknownTeamIsNoChange() {
        let previous = TestData.appSnapshot([TestData.installedApp(signing: .unknown)])
        let current = TestData.appSnapshot([TestData.installedApp()]).carryingForwardAppState(from: previous)
        #expect(current.installedApps.first?.teamIDChange == nil)
    }

    /// Review M2: Ohne Signaturergebnis bleibt die zuletzt bekannte Herkunft, statt sie aus dem Ort zu raten.
    @Test func unverifiedOriginKeepsTheLastKnownOrigin() {
        let previous = TestData.appSnapshot([TestData.installedApp(origin: .direct)])
        let current = TestData.appSnapshot([TestData.installedApp(origin: .unverified, signing: .unknown)], at: TestData.date + TestData.day)
            .carryingForwardAppState(from: previous)
        #expect(current.installedApps.first?.origin == .direct)
        #expect(current.carryingForwardAppState(from: previous) == current, "idempotent")

        let first = TestData.appSnapshot([TestData.installedApp(origin: .unverified, signing: .unknown)])
            .carryingForwardAppState(from: nil)
        #expect(first.installedApps.first?.origin == .unverified)
    }

    /// Review Task 1 (I1): Ein gespeicherter Snapshot mit nicht prüfbarer Signatur darf den Wechsel A → B nicht
    /// verschlucken.
    @Test func teamIDChangeSurvivesAStoredUnknownSnapshot() {
        let teamA = TestData.appSnapshot([TestData.installedApp()])
        // Die Signaturprüfung fällt aus, zugleich ändert sich die Version – dieser Snapshot wird gespeichert.
        let unknown = TestData.appSnapshot(
            [TestData.installedApp(version: "6.1", signing: .unknown, architecture: .unknown)], at: TestData.date + TestData.day
        ).carryingForwardAppState(from: teamA)
        #expect(!unknown.isEquivalent(to: teamA))
        #expect(unknown.installedApps.first?.signing == TestData.developerSigning, "letzte bekannte Signatur")
        #expect(unknown.installedApps.first?.architecture == .universal, "letzte bekannte Architektur")
        #expect(SnapshotDiffer().diff(from: teamA, to: unknown).map(\.kind) == [.modified])

        let teamBSnapshot = TestData.appSnapshot(
            [TestData.installedApp(version: "6.1", signing: teamB)], at: TestData.date + 2 * TestData.day
        ).carryingForwardAppState(from: unknown)
        let change = TeamIDChange(previousTeamID: "TEAMA12345", detectedAt: TestData.date + 2 * TestData.day)
        #expect(teamBSnapshot.installedApps.first?.teamIDChange == change)
        let events = SnapshotDiffer().diff(from: unknown, to: teamBSnapshot)
        #expect(events.map { ChangeDescription($0).title } == ["Entwickler-Team einer App geändert"])
        #expect(TeamIDChangedRule().evaluate(teamBSnapshot).map(\.severity) == [.high])
    }

    /// Eine Prüfung, die zwar keine Signaturart, aber eine Team-ID liefert, behält diese – ein anderes Team ist ein Wechsel.
    @Test func unknownKindWithOtherTeamIsAChangeAndNotOverwritten() {
        let previous = TestData.appSnapshot([TestData.installedApp()])
        let current = TestData.appSnapshot([TestData.installedApp(signing: SigningInfo(kind: .unknown, teamID: "TEAMB67890"))])
            .carryingForwardAppState(from: previous)
        #expect(current.installedApps.first?.signing == SigningInfo(kind: .unknown, teamID: "TEAMB67890"))
        #expect(current.installedApps.first?.teamIDChange?.previousTeamID == "TEAMA12345")
    }

    /// Fehlt die Team-ID bei bekannter Signaturart (ad hoc, unsigniert), bleibt die Signatur unverändert; der Vergleich
    /// mit der nächsten Team-ID nutzt die zuletzt bekannte.
    @Test func teamIDChangeAcrossASignatureWithoutTeam() {
        let teamA = TestData.appSnapshot([TestData.installedApp()])
        let adHoc = TestData.appSnapshot([TestData.installedApp(signing: SigningInfo(kind: .adHoc))], at: TestData.date + 60)
            .carryingForwardAppState(from: teamA)
        #expect(adHoc.installedApps.first?.signing == SigningInfo(kind: .adHoc))
        #expect(adHoc.installedApps.first?.lastKnownTeamID == "TEAMA12345")
        #expect(adHoc.carryingForwardAppState(from: teamA) == adHoc, "idempotent")

        let teamBSnapshot = TestData.appSnapshot([TestData.installedApp(signing: teamB)], at: TestData.date + 120)
            .carryingForwardAppState(from: adHoc)
        #expect(teamBSnapshot.installedApps.first?.teamIDChange == TeamIDChange(previousTeamID: "TEAMA12345",
                                                                               detectedAt: TestData.date + 120))
        #expect(teamBSnapshot.installedApps.first?.lastKnownTeamID == nil)

        let sameTeam = TestData.appSnapshot([TestData.installedApp()], at: TestData.date + 120)
            .carryingForwardAppState(from: adHoc)
        #expect(sameTeam.installedApps.first?.teamIDChange == nil)
    }

    @Test func teamIDChangeIsHighForThirtyDays() {
        var app = TestData.installedApp(signing: teamB)
        app.teamIDChange = TeamIDChange(previousTeamID: "TEAMA12345", detectedAt: TestData.date)
        let fresh = TeamIDChangedRule().evaluate(TestData.appSnapshot([app], at: TestData.date + 30 * TestData.day))
        #expect(fresh == [RiskFinding(rule: .teamIDChanged, severity: .high, recordID: app.id,
                                      message: "Zoom: Entwickler-Team gewechselt (TEAMA12345 → TEAMB67890)")])
        #expect(TeamIDChangedRule().evaluate(TestData.appSnapshot([app], at: TestData.date + 31 * TestData.day)).isEmpty)
    }

    // MARK: Unsigniert, Intel

    @Test func unsignedAndAdHocAreMedium() {
        let unsigned = TestData.installedApp("Tool", bundleID: "com.example.tool", signing: SigningInfo(kind: .unsigned))
        let adHoc = TestData.installedApp("Other", bundleID: "com.example.other", signing: SigningInfo(kind: .adHoc))
        let signed = TestData.installedApp()
        let unknown = TestData.installedApp("Unknown", bundleID: "com.example.unknown", signing: .unknown)
        let findings = UnsignedAppRule().evaluate(TestData.appSnapshot([unsigned, adHoc, signed, unknown]))
        #expect(findings.map(\.recordID) == [unsigned.id, adHoc.id])
        #expect(findings.map(\.message) == ["Tool ist nicht signiert", "Other ist nur ad hoc signiert"])
        #expect(findings.allSatisfy { $0.severity == .medium && $0.rule == .unsignedApp })
    }

    /// Review Task 2 (M2): Die Homebrew-Herkunft stammt aus dem beschreibbaren Caskroom und ist fälschbar. Sie senkt ad
    /// hoc nur auf niedrig; eine völlig fehlende Signatur bleibt mittel.
    @Test func homebrewOnlyLowersAdHocToLow() {
        let adHoc = TestData.installedApp("darktable", bundleID: "org.darktable", origin: .homebrew(cask: "darktable"),
                                          signing: SigningInfo(kind: .adHoc))
        let unsigned = TestData.installedApp("Fake", bundleID: "com.example.fake", origin: .homebrew(cask: "fake"),
                                             signing: SigningInfo(kind: .unsigned))
        #expect(UnsignedAppRule().evaluate(TestData.appSnapshot([adHoc, unsigned])) == [
            RiskFinding(rule: .unsignedApp, severity: .low, recordID: adHoc.id, message: "darktable ist nur ad hoc signiert"),
            RiskFinding(rule: .unsignedApp, severity: .medium, recordID: unsigned.id, message: "Fake ist nicht signiert"),
        ])
    }

    /// Eine Safari-Web-App bringt kein eigenes Programm mit – ihre Ad-hoc-Signatur ist kein Befund. Chromium-App-Shims
    /// haben eigenen Code und sind nur an der Bundle-ID erkannt: ad hoc sinkt auf niedrig, unsigniert bleibt mittel.
    @Test func webAppsAreNoFindingOrLow() {
        let safari = TestData.installedApp("Homelab", bundleID: "com.apple.Safari.WebApp.6E59019D",
                                           origin: .webApp(browser: .safari), signing: SigningInfo(kind: .adHoc))
        let chrome = TestData.installedApp("YouTube", bundleID: "com.google.Chrome.app.agimnkijcaahngcdmfeangaknmldooml",
                                           origin: .webApp(browser: .chrome), signing: SigningInfo(kind: .adHoc))
        let unsigned = TestData.installedApp("Fake", bundleID: "com.google.Chrome.app.fake",
                                             origin: .webApp(browser: .chrome), signing: SigningInfo(kind: .unsigned))
        #expect(UnsignedAppRule().evaluate(TestData.appSnapshot([safari, chrome, unsigned])) == [
            RiskFinding(rule: .unsignedApp, severity: .low, recordID: chrome.id, message: "YouTube ist nur ad hoc signiert"),
            RiskFinding(rule: .unsignedApp, severity: .medium, recordID: unsigned.id, message: "Fake ist nicht signiert"),
        ])
    }

    /// Echte Apple-Apps sind nie unsigniert oder ad hoc signiert; eine `com.apple.`-Kennung ohne Signatur ist daher
    /// kein Ausnahmegrund (sie lässt sich im eigenen Info.plist frei setzen).
    @Test func appleBundleIDDoesNotExemptAnUnsignedApp() {
        let disguised = TestData.installedApp("Keynote", bundleID: "com.apple.Keynote", signing: SigningInfo(kind: .unsigned))
        #expect(UnsignedAppRule().evaluate(TestData.appSnapshot([disguised])).map(\.severity) == [.medium])
    }

    @Test func intelOnlyIsLow() {
        let intel = TestData.installedApp("GLKVM", bundleID: "com.example.glkvm", architecture: .intel)
        let others = [AppArchitecture.universal, .appleSilicon, .unknown].map {
            TestData.installedApp("App \($0.rawValue)", bundleID: "com.example.\($0.rawValue)", architecture: $0)
        }
        #expect(IntelOnlyRule().evaluate(TestData.appSnapshot([intel] + others)) == [
            RiskFinding(rule: .intelOnly, severity: .low, recordID: intel.id, message: "GLKVM läuft nur über Rosetta (Intel)"),
        ])
    }

    // MARK: Tiefenprüfung

    @Test func invalidSignatureCoversThirdPartyApps() {
        let app = TestData.installedApp()
        let keynote = TestData.installedApp("Keynote", bundleID: "com.apple.Keynote", origin: .appStore,
                                            signing: SigningInfo(kind: .appStore, isNotarized: true))
        let adHoc = TestData.installedApp("Tool", bundleID: "com.example.tool", signing: SigningInfo(kind: .adHoc))
        let grant = TestData.grant("kTCCServiceScreenCapture", client: app.identity)
        let snapshot = TestData.appSnapshot([app, keynote, adHoc], grants: [grant])
        #expect(InvalidSignatureRule.verificationTargets(in: snapshot) == [app.path])
        let findings = InvalidSignatureRule().evaluate(snapshot, signatures: [app.path: .invalid(status: errSecCSBadResource)])
        #expect(findings.map(\.recordID) == [grant.id, app.id])
        #expect(findings.last?.message.hasPrefix("Signatur von Zoom ist ungültig oder verändert") == true)
    }

    /// Nur echte Apple-Apps sind von der Tiefenprüfung ausgenommen (Review Task 4): Apple-signiert, App-Store-signiert
    /// mit Apple-Kennung oder ohne Signaturergebnis im versiegelten System. Eine `com.apple.`-Kennung allein lässt sich in
    /// jedem Info.plist setzen; Xcode-ähnliche Pfade in `/Applications` sind beschreibbar.
    @Test func invalidSignatureExemptsOnlyGenuineAppleApps() {
        let fake = TestData.installedApp("Fake", bundleID: "com.apple.fake")
        let helper = TestData.installedApp("Xcode-helper", bundleID: "com.apple.dt.helper", signing: .unknown)
        let keynote = TestData.installedApp("Keynote", bundleID: "com.apple.Keynote", origin: .appStore,
                                            signing: SigningInfo(kind: .appStore, teamID: "74J34U3R6X", isNotarized: true))
        let safari = TestData.installedApp("Safari", bundleID: "com.apple.Safari", signing: SigningInfo(kind: .apple, isNotarized: true))
        let calculator = TestData.installedApp("Rechner", bundleID: "com.apple.calculator",
                                               path: "/System/Applications/Calculator.app", signing: .unknown)
        let snapshot = TestData.appSnapshot([fake, helper, keynote, safari, calculator])
        #expect(InvalidSignatureRule.verificationTargets(in: snapshot) == [fake.path, helper.path])
        let findings = InvalidSignatureRule().evaluate(snapshot, signatures: [fake.path: .invalid(status: errSecCSBadResource)])
        #expect(findings.map(\.recordID) == [fake.id])
    }

    // MARK: Symlink-Bundles (Review M3)

    private func symlinked(to target: String = "/Users/x/Downloads/Real.app") -> InstalledApp {
        var app = TestData.installedApp("Real", bundleID: nil, origin: .unverified, signing: .unknown, architecture: .unknown)
        app.symlinkTarget = target
        return app
    }

    @Test func symlinkedAppIsALowFindingAndNeverDeepVerified() {
        let link = symlinked()
        let snapshot = TestData.appSnapshot([link])
        #expect(SymlinkedAppRule().evaluate(snapshot) == [
            RiskFinding(rule: .symlinkedApp, severity: .low, recordID: link.id,
                        message: "Real verweist auf eine App außerhalb der App-Ordner: /Users/x/Downloads/Real.app"),
        ])
        #expect(InvalidSignatureRule.verificationTargets(in: snapshot).isEmpty)
        #expect(RiskEvaluator.standard.evaluate(snapshot).map(\.rule) == [.symlinkedApp])
    }

    /// Ein Symlink übernimmt nie Signatur, Herkunft oder Architektur der früheren echten App am selben Pfad.
    @Test func symlinkReplacingAnAppCarriesNothingAndIsSignificant() {
        let real = TestData.installedApp("Real", bundleID: "com.example.real")
        let previous = TestData.appSnapshot([real])
        let current = TestData.appSnapshot([symlinked()], at: TestData.date + TestData.day).carryingForwardAppState(from: previous)
        let app = current.installedApps.first
        #expect(app?.signing == .unknown)
        #expect(app?.origin == .unverified)
        #expect(app?.architecture == .unknown)
        #expect(symlinked().hasSignificantChanges(comparedTo: symlinked(to: "/tmp/Other.app")))
        #expect(!symlinked().hasSignificantChanges(comparedTo: symlinked()))
    }

    @Test func standardEvaluatorIncludesAppRules() {
        let snapshot = TestData.appSnapshot([TestData.installedApp(architecture: .intel)])
        #expect(RiskEvaluator.standard.evaluate(snapshot).map(\.rule) == [.intelOnly])
    }
}
