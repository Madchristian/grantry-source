import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Größe = Länge des Pfads (deterministisch, ohne Dateisystem).
private struct PathLengthSizer: FileSizeMeasuring {
    func allocatedSize(of path: String) -> Int64? { Int64(path.count) }
}

/// Penetrationstests (Audit 2026-10-09, Bereich App-Identität): Die Bundle-ID einer App stammt aus ihrer Info.plist
/// und ist frei wählbar – auch für eine unsignierte App in `/Applications`. Trägt sie die Bundle-ID eines fremden
/// Herstellers (EDR-, MDM-, Backup-Agent), darf sie beim Entfernen nicht dessen LaunchDaemon, TCC-Rechte oder
/// systemweite Dateien vorausgewählt bekommen: Der root-Helper würde den Daemon entladen und löschen, `tccutil reset`
/// dem Hersteller seine Rechte nehmen – nur weil der Nutzer eine als „sicher“ dargestellte Vorauswahl bestätigt.
@Suite struct PenetrationAppIdentitySpoofingTests {
    /// Dienst eines fremden Herstellers, dessen Programm in einer App **außerhalb** der App-Wurzeln liegt – so
    /// installieren sich viele Agenten; das App-Inventar kennt dieses Bundle nicht.
    private static let vendorAgentPath = "/Library/Application Support/Vendor/Agent.app"
    private static let vendor = AppIdentity(
        bundleID: "com.vendor.agent", path: vendorAgentPath, displayName: "Vendor Agent",
        signing: SigningInfo(kind: .developerID, teamID: "VENDOR1234", isNotarized: true), presence: .present
    )
    /// Nachgemachte App in `/Applications`: gleiche Bundle-ID, unsigniert.
    private static let lookalike = TestData.installedApp(
        "Agent", bundleID: "com.vendor.agent", path: "/Applications/Agent.app", signing: SigningInfo(kind: .unsigned)
    )

    private static func vendorDaemon() -> AutostartItem {
        var item = TestData.item("com.vendor.agent", kind: .launchDaemon, domain: .system, owner: vendor)
        item.program = vendorAgentPath + "/Contents/MacOS/agentd"
        item.plistPath = "/Library/LaunchDaemons/com.vendor.agent.plist"
        return item
    }

    private static func review(_ links: AppLinks) -> RemovalReview {
        RemovalReview(leftovers: LeftoverScanResult(candidates: []), links: links, home: "/Users/test")
    }

    /// Befund A1: Die Zuordnung hält die Bundle-ID für belastbar, sobald keine zweite Installation im Inventar steht.
    /// Der Anker des Daemons (sein Programmpfad) liegt in einem fremden Bundle – das ist kein Beleg für Exklusivität.
    @Test func lookalikeDoesNotGetTheVendorsLaunchDaemonPreselected() {
        let daemon = Self.vendorDaemon()
        let snapshot = TestData.appSnapshot([Self.lookalike], items: [daemon])
        let review = Self.review(AppLinks.of(Self.lookalike, in: snapshot))
        #expect(!review.initialSelection.selected.contains(daemon.id))
    }

    /// Befund A1, TCC: `tccutil reset <Dienst> com.vendor.agent` träfe die Rechte des Herstellers.
    @Test func lookalikeDoesNotGetTheVendorsGrantPreselected() {
        let grant = TestData.grant(client: Self.vendor)
        let snapshot = TestData.appSnapshot([Self.lookalike], grants: [grant])
        let review = Self.review(AppLinks.of(Self.lookalike, in: snapshot))
        #expect(ActionPolicy().availability(for: grant) == .available, "Vorbedingung: der Reset wäre ausführbar")
        #expect(!review.initialSelection.selected.contains(grant.id))
    }

    /// Gegenprobe (heute korrekt): Steht die echte App im Inventar, ist der Daemon ein Konflikt und bleibt weg.
    @Test func lookalikeNextToTheRealAppGetsNothing() {
        let real = TestData.installedApp("Vendor Agent", bundleID: "com.vendor.agent", path: "/Applications/Vendor Agent.app")
        var daemon = Self.vendorDaemon()
        daemon.program = real.path + "/Contents/MacOS/agentd"
        let snapshot = TestData.appSnapshot([Self.lookalike, real], items: [daemon])
        let links = AppLinks.of(Self.lookalike, in: snapshot)
        #expect(links.autostartItems.isEmpty)
        #expect(Self.review(links).initialSelection.selected.isEmpty)
    }

    /// Befund A2: Systemweite Reste (`/Library/…`) eines fremden Herstellers gelten für die nachgemachte App als
    /// „Zuordnung sicher“ und sind vorausgewählt – der Finder fragt nach dem Admin-Passwort, der Nutzer sieht „sicher“.
    @Test func lookalikeDoesNotGetSystemWideFilesOfTheVendorPreselected() async throws {
        try await LibraryFixture.with { fixture in
            let path = try fixture.app("Agent", bundleID: "com.vendor.agent")
            let lookalike = TestData.installedApp("Agent", bundleID: "com.vendor.agent", path: path,
                                                  signing: SigningInfo(kind: .unsigned))
            let systemWide = [
                try fixture.file(fixture.system("Library/Preferences/com.vendor.agent.plist")),
                try fixture.folder(fixture.system("Library/Application Support/com.vendor.agent")),
            ]
            let candidates = await LeftoverScanner(layout: fixture.layout, sizes: PathLengthSizer(), appSizes: PathLengthSizer())
                .scan(for: lookalike, installedApps: [lookalike]).candidates
            let found = candidates.filter { systemWide.contains($0.path) }
            #expect(found.count == systemWide.count, "Vorbedingung: beide Funde werden gelistet")
            #expect(found.allSatisfy { !$0.isPreselected })
        }
    }
}
