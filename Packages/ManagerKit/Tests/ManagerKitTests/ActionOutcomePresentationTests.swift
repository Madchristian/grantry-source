import Foundation
import Testing
import ManagerKit

@Suite struct ActionOutcomePresentationTests {
    private let camera = PermissionGrant(
        service: "kTCCServiceCamera",
        client: AppIdentity(bundleID: "us.zoom.xos", path: nil, displayName: "Zoom", signing: .unknown, presence: .present),
        authValue: .allowed, scope: .user, lastModified: Date(timeIntervalSince1970: 0)
    )

    @Test func doneShowsTheSuccessMessage() {
        let presentation = ActionOutcomePresentation.reset(camera, outcome: .done)
        #expect(presentation.text == "Kamera-Berechtigung von Zoom wurde zurückgesetzt.")
        #expect(presentation.tone == .positive)
        #expect(presentation.settingsURL == nil)
        #expect(presentation.systemImage == PresentationTone.positive.systemImage)
    }

    @Test func unverifiedKeepsReasonAndDeeplink() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        let presentation = ActionOutcomePresentation(.doneButUnverified("Noch eingetragen", settingsURL: url), successMessage: "ok")
        #expect(presentation.text == "Noch eingetragen")
        #expect(presentation.tone == .warning)
        #expect(presentation.settingsURL == url)
    }

    @Test func failureShowsTheError() {
        let presentation = ActionOutcomePresentation(.failed("tccutil fehlgeschlagen"), successMessage: "ok")
        #expect(presentation.text == "tccutil fehlgeschlagen")
        #expect(presentation.tone == .critical)
        #expect(presentation.settingsURL == nil)
    }
}

@Suite struct IdentityPresentationTests {
    @Test(arguments: [
        (SigningInfo(kind: .apple), "Apple", PresentationTone.positive),
        (SigningInfo(kind: .appStore), "App Store", .positive),
        (SigningInfo(kind: .developerID, isNotarized: true), "Developer ID, notarisiert", .positive),
        (SigningInfo(kind: .developerID), "Developer ID, nicht notarisiert", .warning),
        (SigningInfo(kind: .development), "Entwicklerzertifikat (lokaler Build)", .warning),
        (SigningInfo(kind: .adHoc), "Ad-hoc-signiert", .warning),
        (SigningInfo(kind: .unsigned), "Nicht signiert", .critical),
        (SigningInfo.unknown, "Unbekannt", .neutral),
    ])
    func describesSigning(signing: SigningInfo, text: String, tone: PresentationTone) {
        #expect(signing.displayName == text)
        #expect(signing.tone == tone)
    }

    @Test(arguments: [
        (SigningInfo(kind: .apple), "Apple"),
        (SigningInfo(kind: .appStore), "App Store"),
        (SigningInfo(kind: .developerID, isNotarized: true), "Developer ID"),
        (SigningInfo(kind: .developerID), "Developer ID"),
        (SigningInfo(kind: .development), "Entwickler"),
        (SigningInfo(kind: .adHoc), "Ad hoc"),
        (SigningInfo(kind: .unsigned), "Unsigniert"),
        (SigningInfo.unknown, "Unbekannt"),
    ])
    func shortensSigning(signing: SigningInfo, text: String) {
        #expect(signing.shortName == text)
    }

    @Test func describesPresenceScopeAndAuthValue() {
        #expect(Presence.present.displayName == "Vorhanden")
        #expect(Presence.missing.displayName == "Nicht mehr vorhanden")
        #expect(Presence.probablyMissing.displayName == "Vermutlich entfernt")
        #expect(Presence.unknown.displayName == "Nicht feststellbar")
        #expect(TCCScope.user.displayName == "Benutzer")
        #expect(TCCScope.system.displayName == "System")
        #expect(AuthValue.allowed.displayName == "erlaubt")
        #expect(AuthValue.denied.displayName == "verweigert")
        #expect(AuthValue.allowed.tone == .positive)
        #expect(AuthValue.limited.tone == .warning)
        #expect(AuthValue.denied.tone == .neutral)
        #expect(AutostartKind.launchDaemon.displayName == "LaunchDaemon")
    }

    @Test func serviceResetLinksToSettingsWhenInstalledAppsLostTheGrant() throws {
        let orphan = TestData.grant("kTCCServiceAccessibility", client: TestData.app("ai.gone", presence: .missing), scope: .system)
        let installed = TestData.grant("kTCCServiceAccessibility", scope: .system)
        let withCollateral = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [orphan, installed])))
        let done = ActionOutcomePresentation.resetService(withCollateral, outcome: .done)
        #expect(done.text == "Bedienungshilfen wurde für alle Apps zurückgesetzt. Erlaube installierte Apps bei Bedarf neu.")
        #expect(done.tone == .positive)
        #expect(done.settingsURL == PermissionCatalog.service(for: "kTCCServiceAccessibility").settingsURL)
        let onlyOrphans = try #require(ServiceReset(service: "kTCCServiceAccessibility", in: TestData.snapshot(grants: [orphan])))
        #expect(ActionOutcomePresentation.resetService(onlyOrphans, outcome: .done).settingsURL == nil)
        #expect(ActionOutcomePresentation.resetService(withCollateral, outcome: .failed("x")).tone == .critical)
    }
}
