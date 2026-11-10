import Foundation
import Testing
@testable import ManagerKit

/// Verlaufs- und Benachrichtigungstexte der Erweiterungen (TM-13.3): neu, entfernt, neue Version, Zustandswechsel.
@Suite struct ExtensionChangeDescriptionTests {
    private let owner = ExtensionOwnership.app(path: "/Applications/Vendor Suite.app", evidence: .bundleID)

    private func event(_ kind: ChangeEvent.Kind, _ before: ExtensionRecord?, _ after: ExtensionRecord?) -> ChangeEvent {
        ChangeEvent(kind: kind, before: before.map(ChangeSubject.extensionRecord), after: after.map(ChangeSubject.extensionRecord),
                    detectedAt: TestData.date)
    }

    @Test func addedNamesKindVersionStateAndApp() {
        let description = ChangeDescription(event(.added, nil, TestData.extensionRecord(owner: owner)))
        #expect(description.title == "Neue Erweiterung")
        #expect(description.body == "Vendor Filter (Netzwerkerweiterung) von Vendor Suite: Version 1.0, aktiv.")
    }

    /// Ohne Namen die Bundle-ID; ohne Version nur der Zustand; Build nur, wenn er von der Version abweicht.
    @Test func addedWithoutNameOrVersion() {
        var record = TestData.extensionRecord(kind: .endpointSecurity, name: nil, version: nil, state: .waitingForUser)
        #expect(ChangeDescription(event(.added, nil, record)).body
            == "com.vendor.filter (Endpoint Security): wartet auf Freigabe.")
        record.version = "6.2.1"
        record.buildVersion = "6224"
        #expect(ChangeDescription(event(.added, nil, record)).body
            == "com.vendor.filter (Endpoint Security): Version 6.2.1 (6224), wartet auf Freigabe.")
    }

    @Test func removed() {
        let description = ChangeDescription(event(.removed, TestData.kernelExtensionRecord(), nil))
        #expect(description.title == "Erweiterung entfernt")
        #expect(description.body == "Vendor Kext (Kernel-Erweiterung).")
    }

    @Test func newVersion() {
        let description = ChangeDescription(event(.modified, TestData.pluginRecord(version: "1.0"), TestData.pluginRecord(version: "2.0")))
        #expect(description.title == "Erweiterung aktualisiert")
        #expect(description.body == "Vendor Audio (Audio-Plug-in): Version 1.0 → 2.0.")
    }

    /// Jeder Zustandswechsel hat einen eigenen Titel; der Text nennt vorher und nachher.
    @Test(arguments: [
        (ExtensionState.enabled, ExtensionState.removalPending, "Erweiterung wird beim Neustart entfernt", "aktiv → wird beim Neustart entfernt"),
        (.waitingForUser, .enabled, "Erweiterung aktiviert", "wartet auf Freigabe → aktiv"),
        (.enabled, .disabled, "Erweiterung deaktiviert", "aktiv → deaktiviert"),
        (.enabled, .waitingForUser, "Erweiterung wartet auf Freigabe", "aktiv → wartet auf Freigabe"),
        (.notLoaded, .loaded, "Kernel-Erweiterung geladen", "nicht geladen → geladen"),
        (.loaded, .notLoaded, "Kernel-Erweiterung nicht mehr geladen", "geladen → nicht geladen"),
        (.enabled, .unknown("strange"), "Zustand einer Erweiterung geändert", "aktiv → unbekannt (strange)"),
    ])
    func stateChange(before: ExtensionState, after: ExtensionState, title: String, change: String) {
        let description = ChangeDescription(event(.modified, TestData.extensionRecord(state: before), TestData.extensionRecord(state: after)))
        #expect(description.title == title)
        #expect(description.body == "Vendor Filter (Netzwerkerweiterung): \(change).")
    }

    /// Neue Version und Zustand zugleich: Die Version bestimmt den Titel, der Text nennt beides.
    @Test func newVersionWithStateChange() {
        let description = ChangeDescription(event(
            .modified, TestData.extensionRecord(version: "1.0"), TestData.extensionRecord(version: "2.0", state: .waitingForUser)
        ))
        #expect(description.title == "Erweiterung aktualisiert")
        #expect(description.body == "Vendor Filter (Netzwerkerweiterung): Version 1.0 → 2.0, aktiv → wartet auf Freigabe.")
    }

    @Test func signingChange() {
        let description = ChangeDescription(event(
            .modified, TestData.pluginRecord(), TestData.pluginRecord(signing: SigningInfo(kind: .adHoc, teamID: "OTHERTEAM1"))
        ))
        #expect(description.title == "Signatur einer Erweiterung geändert")
        #expect(description.body == "Vendor Audio (Audio-Plug-in): Signatur Developer ID → ad hoc, Team-ID TEAMPLUG01 → OTHERTEAM1.")
    }

    /// Fremde Namen bleiben einzeilig und begrenzt (Spec § 4.5).
    @Test func foreignNamesStayOnOneBoundedLine() {
        let record = TestData.extensionRecord(name: "Evil\nFilter\u{202E}" + String(repeating: "x", count: 400))
        let description = ChangeDescription(event(.added, nil, record))
        #expect(!description.body.contains("\n"))
        #expect(description.body.count <= 240)
    }

    @Test func kindAndLayerNames() {
        #expect(ExtensionKind.otherSystemExtension("com.apple.system_extension.x").displayName == "Systemerweiterung")
        #expect(ExtensionKind.camera.displayName == "Kameraerweiterung")
        #expect(ExtensionKind.driver.displayName == "Treiber")
        #expect(ExtensionKind.videoPlugin.displayName == "Video-Plug-in")
        #expect(ExtensionLayer.allCases.map(\.displayName) == [
            "Im Kern", "Systemerweiterung mit Sonderrechten", "Treiber", "Plug-in in einem Systemdienst",
        ])
    }

    // MARK: Benachrichtigung, Ziel, Verlauf

    /// Neue Erweiterungen melden sich immer, ein Signatur- oder Teamwechsel auch; Versionen, Zustände und Entfernen
    /// stehen nur im Verlauf.
    @Test func notificationPolicy() {
        let policy = NotificationPolicy()
        #expect(policy.shouldNotify(event(.added, nil, TestData.extensionRecord())))
        #expect(policy.shouldNotify(event(.modified, TestData.pluginRecord(), TestData.pluginRecord(signing: SigningInfo(kind: .adHoc)))))
        #expect(!policy.shouldNotify(event(.modified, TestData.pluginRecord(version: "1"), TestData.pluginRecord(version: "2"))))
        #expect(!policy.shouldNotify(event(.modified, TestData.extensionRecord(), TestData.extensionRecord(state: .removalPending))))
        #expect(!policy.shouldNotify(event(.removed, TestData.extensionRecord(), nil)))
    }

    /// Bis zum Bereich „Erweiterungen“ (TM-13.5) führt die Meldung in den Verlauf.
    @Test func notificationLeadsToHistory() {
        #expect(NotificationDestination(for: event(.added, nil, TestData.extensionRecord())) == .history)
    }

    @Test func historyCategory() {
        let added = HistoryEvent(id: UUID(), event: event(.added, nil, TestData.extensionRecord()), isRead: false)
        let app = HistoryEvent(id: UUID(), event: ChangeEvent(kind: .added, before: nil, after: .installedApp(TestData.installedApp()),
                                                               detectedAt: TestData.date), isRead: false)
        let filter = HistoryFilter(category: .extensions)
        #expect(HistoryFilter.Category.extensions.displayName == "Erweiterungen")
        #expect(filter.matches(added, now: TestData.date))
        #expect(!filter.matches(app, now: TestData.date))
        #expect(!HistoryFilter(category: .apps).matches(added, now: TestData.date))
    }
}
