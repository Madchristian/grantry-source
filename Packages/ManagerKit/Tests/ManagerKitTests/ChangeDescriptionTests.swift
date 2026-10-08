import Foundation
import Testing
@testable import ManagerKit

@Suite("ChangeDescription")
struct ChangeDescriptionTests {
    private static let zoom = AppIdentity(
        bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app", displayName: "Zoom", signing: .unknown, presence: .present
    )
    private static let docker = AppIdentity(
        bundleID: "com.docker.docker", path: "/Applications/Docker.app", displayName: "Docker", signing: .unknown,
        presence: .present
    )

    private func grant(
        _ service: String = "kTCCServiceCamera", authValue: AuthValue = .allowed, target: String? = nil
    ) -> ChangeSubject {
        .grant(
            PermissionGrant(
                service: service, client: Self.zoom, authValue: authValue, scope: .user, lastModified: TestData.date,
                target: target
            )
        )
    }

    private func item(
        kind: AutostartKind = .launchDaemon, owner: AppIdentity? = docker, isEnabled: Bool = true,
        isLoaded: Bool? = true, program: String? = "/Library/PrivilegedHelperTools/com.docker.helper"
    ) -> ChangeSubject {
        .autostartItem(
            AutostartItem(
                kind: kind, domain: .system, label: "com.docker.helper", program: program, programPresence: .present,
                isEnabled: isEnabled, isLoaded: isLoaded, plistPath: nil, owner: owner, source: .launchd
            )
        )
    }

    private func describe(
        _ kind: ChangeEvent.Kind, before: ChangeSubject? = nil, after: ChangeSubject? = nil
    ) -> ChangeDescription {
        ChangeDescription(ChangeEvent(kind: kind, before: before, after: after, detectedAt: TestData.date))
    }

    // MARK: Berechtigungen

    @Test func addedAllowedGrant() {
        let description = describe(.added, after: grant("kTCCServiceScreenCapture"))
        #expect(description == ChangeDescription(title: "Neue Berechtigung", body: "Zoom darf jetzt Bildschirmaufnahme."))
    }

    @Test func addedLimitedGrant() {
        let description = describe(.added, after: grant("kTCCServicePhotos", authValue: .limited))
        #expect(description.body == "Zoom darf jetzt Fotos (eingeschränkt).")
    }

    @Test func addedDeniedGrant() {
        let description = describe(.added, after: grant(authValue: .denied))
        #expect(description == ChangeDescription(title: "Neue Berechtigung", body: "Zoom: Kamera verweigert."))
    }

    @Test func addedGrantWithUnknownAuthValue() {
        let description = describe(.added, after: grant(authValue: .unknown(5)))
        #expect(description.body == "Zoom: Kamera unbekannt (5).")
    }

    @Test func unknownServiceFallsBackToRawID() {
        let description = describe(.added, after: grant("kTCCServiceNeu"))
        #expect(description.body == "Zoom darf jetzt kTCCServiceNeu.")
    }

    @Test func automationGrantMentionsTarget() {
        let description = describe(.added, after: grant("kTCCServiceAppleEvents", target: "com.apple.finder"))
        #expect(description.body == "Zoom darf jetzt Automation (Ziel: com.apple.finder).")
    }

    @Test func modifiedGrantShowsTransition() {
        let description = describe(.modified, before: grant(), after: grant(authValue: .denied))
        #expect(description == ChangeDescription(title: "Berechtigung geändert", body: "Zoom: Kamera erlaubt → verweigert."))
    }

    @Test func modifiedGrantToLimited() {
        let description = describe(.modified, before: grant(authValue: .denied), after: grant(authValue: .limited))
        #expect(description.body == "Zoom: Kamera verweigert → eingeschränkt.")
    }

    @Test func removedGrant() {
        let description = describe(.removed, before: grant("kTCCServiceMicrophone"))
        #expect(description == ChangeDescription(title: "Berechtigung entfernt", body: "Zoom: Mikrofon-Eintrag entfernt."))
    }

    // MARK: Autostart

    @Test func addedAutostartItemWithOwner() {
        let description = describe(.added, after: item())
        #expect(
            description == ChangeDescription(
                title: "Neuer Autostart-Eintrag", body: "com.docker.helper (LaunchDaemon) von Docker."
            )
        )
    }

    @Test func addedAutostartItemWithoutOwner() {
        let description = describe(.added, after: item(owner: nil))
        #expect(description.body == "com.docker.helper (LaunchDaemon).")
    }

    @Test(arguments: [
        (AutostartKind.launchAgent, "LaunchAgent"),
        (.launchDaemon, "LaunchDaemon"),
        (.loginItem, "Anmeldeobjekt"),
        (.backgroundTask, "Hintergrundobjekt"),
    ])
    func autostartKindNames(kind: AutostartKind, name: String) {
        let description = describe(.added, after: item(kind: kind, owner: nil))
        #expect(description.body == "com.docker.helper (\(name)).")
    }

    @Test func removedAutostartItem() {
        let description = describe(.removed, before: item())
        #expect(
            description == ChangeDescription(
                title: "Autostart-Eintrag entfernt", body: "com.docker.helper (LaunchDaemon) von Docker."
            )
        )
    }

    @Test func modifiedAutostartItemDisabled() {
        let description = describe(.modified, before: item(), after: item(isEnabled: false))
        #expect(
            description == ChangeDescription(
                title: "Autostart-Eintrag geändert", body: "com.docker.helper (LaunchDaemon) von Docker: deaktiviert."
            )
        )
    }

    @Test func modifiedAutostartItemEnabled() {
        let description = describe(.modified, before: item(isEnabled: false), after: item())
        #expect(description.body == "com.docker.helper (LaunchDaemon) von Docker: aktiviert.")
    }

    @Test func modifiedAutostartItemLoadState() {
        let unloaded = describe(.modified, before: item(), after: item(isLoaded: false))
        #expect(unloaded.body == "com.docker.helper (LaunchDaemon) von Docker: nicht mehr geladen.")
        let loaded = describe(.modified, before: item(isLoaded: false), after: item())
        #expect(loaded.body == "com.docker.helper (LaunchDaemon) von Docker: jetzt geladen.")
    }

    @Test func unknownLoadStateIsNotMentioned() {
        let description = describe(.modified, before: item(isLoaded: nil), after: item(isEnabled: false, isLoaded: false))
        #expect(description.body == "com.docker.helper (LaunchDaemon) von Docker: deaktiviert.")
    }

    @Test func modifiedAutostartItemProgram() {
        let description = describe(.modified, before: item(), after: item(program: "/usr/local/bin/other"))
        #expect(description.body == "com.docker.helper (LaunchDaemon) von Docker: Programm geändert.")
    }

    @Test func multipleAutostartChangesAreListed() {
        let description = describe(
            .modified, before: item(), after: item(isEnabled: false, isLoaded: false, program: "/usr/local/bin/other")
        )
        #expect(
            description.body
                == "com.docker.helper (LaunchDaemon) von Docker: deaktiviert, nicht mehr geladen, Programm geändert."
        )
    }

    // MARK: Sammelmeldung

    @Test func summaryListsFirstTwoAndEllipsis() {
        let events = [
            ChangeEvent(kind: .added, before: nil, after: grant("kTCCServiceScreenCapture"), detectedAt: TestData.date),
            ChangeEvent(kind: .removed, before: item(), after: nil, detectedAt: TestData.date),
            ChangeEvent(kind: .added, before: nil, after: item(owner: nil), detectedAt: TestData.date),
            ChangeEvent(kind: .added, before: nil, after: grant(), detectedAt: TestData.date),
        ]
        let summary = ChangeDescription.summary(for: events)
        #expect(summary.title == "4 Änderungen")
        #expect(
            summary.body == """
                Neue Berechtigung: Zoom darf jetzt Bildschirmaufnahme.
                Autostart-Eintrag entfernt: com.docker.helper (LaunchDaemon) von Docker.
                …
                """
        )
    }

    @Test func summaryOfTwoHasNoEllipsis() {
        let events = [
            ChangeEvent(kind: .added, before: nil, after: grant(), detectedAt: TestData.date),
            ChangeEvent(kind: .added, before: nil, after: item(owner: nil), detectedAt: TestData.date),
        ]
        let summary = ChangeDescription.summary(for: events)
        #expect(summary.title == "2 Änderungen")
        #expect(summary.body == "Neue Berechtigung: Zoom darf jetzt Kamera.\nNeuer Autostart-Eintrag: com.docker.helper (LaunchDaemon).")
    }
}
