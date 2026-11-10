import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Befunde einer Erweiterung akzeptieren wie bei Apps (#390): Die Akzeptanz übersteht Neustart und Update und endet
/// bei einem Wechsel des Teams.
struct ExtensionRiskAcceptanceTests {
    private typealias R = ExtensionRiskRulesTests

    @Test func acceptanceSurvivesRestartAndVersionUpdateButCanBeRevoked() throws {
        try ScratchDirectory.withCanonical { directory in
            let url = directory.appending(path: "accepted.json")
            var store = ExtensionRiskAcceptanceStore(url: url)
            var kext = Self.kext()
            try store.setAccepted(true, for: kext)
            kext.version = "2.0"
            kext.state = .notLoaded
            var restarted = ExtensionRiskAcceptanceStore(url: url)
            #expect(try restarted.acceptedIDs(in: [kext]) == [kext.id])
            try restarted.setAccepted(false, for: kext)
            var afterRevocation = ExtensionRiskAcceptanceStore(url: url)
            #expect(try afterRevocation.acceptedIDs(in: [kext]).isEmpty)
        }
    }

    @Test func teamChangePermanentlyRevokesAcceptance() throws {
        var store = ExtensionRiskAcceptanceStore()
        let original = Self.kext()
        try store.setAccepted(true, for: original)
        let changed = Self.kext(signing: SigningInfo(kind: .developerID, teamID: "OTHERTEAM"))
        #expect(try store.acceptedIDs(in: [changed]).isEmpty)
        #expect(try store.acceptedIDs(in: [original]).isEmpty)
    }

    /// Bei Systemerweiterungen gehört das Team zur Identität: Eine Erweiterung mit gleicher Bundle-ID und anderem Team
    /// ist ein anderer Eintrag und erbt nichts.
    @Test func systemExtensionOfAnotherTeamDoesNotInheritAcceptance() throws {
        var store = ExtensionRiskAcceptanceStore()
        let original = R.record(.endpointSecurity, owner: .missing)
        try store.setAccepted(true, for: original)
        let impostor = R.record(.endpointSecurity, teamID: "OTHERTEAM", owner: .missing)
        #expect(original.id != impostor.id)
        #expect(try store.acceptedIDs(in: [impostor]).isEmpty)
        #expect(try store.acceptedIDs(in: [original]) == [original.id])
    }

    @Test func signatureKindChangeDoesNotInheritAcceptance() throws {
        var store = ExtensionRiskAcceptanceStore()
        let original = Self.kext(signing: SigningInfo(kind: .adHoc))
        try store.setAccepted(true, for: original)
        #expect(try store.acceptedIDs(in: [Self.kext(signing: SigningInfo(kind: .unsigned))]).isEmpty)
    }

    /// Eine abgelaufene Signaturprüfung belegt keinen Wechsel: Die Akzeptanz gilt in diesem Scan nicht, bleibt aber für
    /// den nächsten erhalten.
    @Test func inconclusiveSigningNeitherAcceptsNorRevokes() throws {
        var store = ExtensionRiskAcceptanceStore()
        let original = Self.kext()
        try store.setAccepted(true, for: original)
        let timedOut = R.record(.kernelExtension, bundleID: original.bundleID, state: .loaded, signing: .unknown,
                                isSigningConclusive: false)
        #expect(timedOut.id == original.id)
        #expect(try store.acceptedIDs(in: [timedOut]).isEmpty)
        #expect(try !store.isAccepted(timedOut))
        #expect(try store.acceptedIDs(in: [original]) == [original.id])
        #expect(throws: RiskAcceptanceError.identityUnknown) { try store.setAccepted(true, for: timedOut) }
    }

    /// Teilscans entfernen keine Akzeptanz fehlender Erweiterungen.
    @Test func missingExtensionsKeepTheirAcceptance() throws {
        var store = ExtensionRiskAcceptanceStore()
        let kext = Self.kext()
        try store.setAccepted(true, for: kext)
        #expect(try store.acceptedIDs(in: []).isEmpty)
        #expect(try store.acceptedIDs(in: [kext]) == [kext.id])
    }

    /// Apps und Erweiterungen teilen die Ablage-Logik; das Format der App-Ablage bleibt lesbar.
    @Test func appAcceptanceFileFormatIsUnchanged() throws {
        try ScratchDirectory.withCanonical { directory in
            let app = TestData.installedApp()
            let url = directory.appending(path: "AppRiskAcceptances.json")
            let legacy = """
            {"\(app.id)":{"bundleID":"us.zoom.xos","teamID":"\(app.signing.teamID ?? "")","signingKind":"developerID"}}
            """
            try Data(legacy.utf8).write(to: url)
            var store = AppRiskAcceptanceStore(url: url)
            #expect(try store.acceptedIDs(in: [app]) == [app.id])
        }
    }

    private static func kext(signing: SigningInfo = SigningInfo(kind: .developerID, teamID: "TEAM1")) -> ExtensionRecord {
        R.record(.kernelExtension, state: .loaded, signing: signing)
    }
}
