import Foundation
import Testing
@testable import ManagerKit

/// Penetrationstests (Audit 2026-10-09, Befund B3): Der Hostname einer Gegenstelle stammt aus dem PTR-Eintrag der
/// Ziel-IP (`getnameinfo`, `NI_NAMEREQD`). Den legt der Betreiber der IP selbst fest – bei jedem VPS per Webformular.
/// Ohne Vorwärtsbestätigung und sichtbare Adresse könnte ein Sammelserver mit PTR `api.github.com` als
/// vertrauenswürdiges Ziel erscheinen. Die Adresse muss deshalb auch mit einem Namen sichtbar bleiben.
@Suite struct PenetrationReverseDNSSpoofingTests {
    private let node = NetworkProgram(executablePath: "/opt/homebrew/bin/node", signing: SigningInfo(kind: .adHoc))

    /// Ein unbestätigter PTR-Name darf die Adresse nicht aus der Zeile verdrängen.
    @Test func reverseNameDoesNotHideTheAddress() throws {
        let frame = TestData.activityFrame([
            TestData.processActivity(3, "node", upload: 1, connections: [
                TestData.connectionActivity(remote: "203.0.113.9", port: 443, upload: 1),
            ]),
        ], programs: [3: node])
        let rows = NetworkActivityPresenter.rows(
            frame: frame, hostNames: ["203.0.113.9": "api.github.com"], filter: NetworkActivityFilter(), query: "",
            sortOrder: NetworkActivityPresenter.defaultSortOrder
        )
        let connection = try #require(rows.first?.children?.first)
        #expect(connection.title.contains("203.0.113.9"), "\(connection.title)")
        #expect(connection.accessibilityLabel.contains("203.0.113.9"))
        #expect(connection.accessibilityLabel.contains("api.github.com"))
        #expect(connection.matches("203.0.113.9"))
        #expect(connection.matches("api.github.com"))
    }
}
