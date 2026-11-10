import Foundation
import Testing
@testable import ManagerKit

/// Erweiterungen als Inventar-Quelle (TM-13.3): Snapshot, Diff und Fortschreiben.
@Suite struct ExtensionSnapshotTests {
    let differ = SnapshotDiffer()
    let later = TestData.date.addingTimeInterval(60)

    private func events(_ previous: Snapshot, _ current: Snapshot) -> Set<String> {
        Set(differ.diff(from: previous, to: current).map { "\($0.kind.rawValue):\($0.subject.recordID)" })
    }

    // MARK: Laden älterer Snapshots

    /// Snapshots vor TM-13.3 kennen die Quelle nicht: Sie laden ohne Fehler, ohne Erweiterungen und ohne Baseline – die
    /// erste Lieferung meldet daher nichts als neu.
    @Test func olderSnapshotsDecodeWithoutExtensions() throws {
        let old = TestData.appSnapshot([TestData.installedApp()], grants: [TestData.grant()])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "extensions")
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.extensions.isEmpty)
        #expect(decoded.grants == old.grants)
        #expect(decoded.installedApps == old.installedApps)
        #expect(!decoded.baselineSources.contains(.extensions))
        var firstDelivery = decoded
        firstDelivery.takenAt = later
        firstDelivery.extensions = [TestData.extensionRecord()]
        #expect(differ.diff(from: decoded, to: firstDelivery).isEmpty)
    }

    /// Ein Snapshot ohne `baselineSources` leitet die Baseline auch aus Erweiterungen ab.
    @Test func entriesDeriveTheirBaseline() {
        let snapshot = Snapshot(takenAt: TestData.date, grants: [], autostartItems: [], extensions: [TestData.extensionRecord()],
                                sourceErrors: [])
        #expect(snapshot.baselineSources == [.extensions])
    }

    @Test func extensionsRoundTrip() throws {
        let snapshot = TestData.extensionSnapshot([
            TestData.extensionRecord(owner: .app(path: "/Applications/Vendor.app", evidence: .bundleID)),
            TestData.extensionRecord("com.vendor.other", kind: .otherSystemExtension("com.apple.system_extension.x"),
                                     state: .unknown("strange"), owner: .unclear(candidates: ["/Applications/A.app"])),
            TestData.kernelExtensionRecord(),
            TestData.pluginRecord(),
        ])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }

    // MARK: Diff und Ereignisse

    @Test func firstDeliveryIsBaseline() {
        let previous = TestData.appSnapshot([])   // `.extensions` noch nicht in der Baseline
        let current = TestData.extensionSnapshot([TestData.extensionRecord(), TestData.pluginRecord()], at: later)
        #expect(differ.diff(from: previous, to: current).isEmpty)
    }

    @Test func reportsAddedRemovedNewVersionAndStateChange() {
        let kept = TestData.extensionRecord("kept")
        let updated = TestData.extensionRecord("updated", version: "1.0")
        let waiting = TestData.extensionRecord("waiting", state: .enabled)
        let gone = TestData.kernelExtensionRecord("gone")
        let previous = TestData.extensionSnapshot([kept, updated, waiting, gone])
        let added = TestData.pluginRecord()
        let current = TestData.extensionSnapshot([
            kept, TestData.extensionRecord("updated", version: "2.0"), TestData.extensionRecord("waiting", state: .removalPending),
            added,
        ], at: later)
        #expect(events(previous, current) == [
            "modified:\(updated.id)", "modified:\(waiting.id)", "removed:\(gone.id)", "added:\(added.id)",
        ])
    }

    /// Name, Pfad, ältere Versionen, „erstmals gesehen“ und die zugehörige App sind Anzeige, keine Änderung.
    @Test func displayOnlyFieldsDoNotReportChanges() {
        let before = TestData.extensionRecord(owner: .app(path: "/Applications/A.app", evidence: .teamID))
        var after = TestData.extensionRecord(name: "Neuer Name", path: "/Library/SystemExtensions/X/vendor.systemextension",
                                             owner: .missing, firstSeenAt: later)
        after.otherVersions = ["0.9"]
        #expect(!after.hasSignificantChanges(comparedTo: before))
        #expect(differ.diff(from: TestData.extensionSnapshot([before]), to: TestData.extensionSnapshot([after], at: later)).isEmpty)
    }

    /// Eine nicht prüfbare Signatur (Zeitüberschreitung) ist kein Wechsel; ein echter Wechsel schon.
    @Test func signingChangesCountOnlyWhenBothAreKnown() {
        let signed = TestData.pluginRecord()
        let unknown = TestData.pluginRecord(signing: .unknown)
        let adHoc = TestData.pluginRecord(signing: SigningInfo(kind: .adHoc))
        let otherTeam = TestData.pluginRecord(signing: SigningInfo(kind: .developerID, teamID: "OTHERTEAM1", isNotarized: true))
        #expect(!unknown.hasSignificantChanges(comparedTo: signed))
        #expect(!signed.hasSignificantChanges(comparedTo: unknown))
        #expect(adHoc.hasSignificantChanges(comparedTo: signed))
        #expect(otherTeam.hasSignificantChanges(comparedTo: signed))
    }

    @Test func equivalenceConsidersExtensions() {
        let base = TestData.extensionSnapshot([TestData.extensionRecord()])
        #expect(base.isEquivalent(to: TestData.extensionSnapshot([TestData.extensionRecord(firstSeenAt: later)], at: later)))
        #expect(!base.isEquivalent(to: TestData.extensionSnapshot([TestData.extensionRecord(version: "2.0")], at: later)))
        #expect(!base.isEquivalent(to: TestData.extensionSnapshot([], at: later)))
    }

    // MARK: Fortschreiben

    @Test func failedSourceKeepsEntries() {
        let record = TestData.extensionRecord()
        let previous = TestData.extensionSnapshot([record])
        let failed = TestData.extensionSnapshot([], errors: [SourceError(source: .extensions, message: "x")], at: later)
            .carryingForwardRecords(ofFailedSourcesFrom: previous)
        #expect(failed.extensions == [record])
        #expect(differ.diff(from: previous, to: failed).isEmpty)
    }

    @Test func partialScanOfOtherSourcesKeepsExtensions() {
        let snapshot = TestData.extensionSnapshot([TestData.extensionRecord()])
        #expect(snapshot.removingRecords(of: [.networkListeners]).extensions == snapshot.extensions)
        #expect(snapshot.removingRecords(of: [.extensions]).extensions.isEmpty)
    }

    /// Eine nicht gelesene Liste (Leser gescheitert oder unvollständig) belegt kein Entfernen: Ihre fehlenden Einträge
    /// werden fortgeschrieben, die der übrigen Listen nicht.
    @Test func incompleteGroupCarriesItsMissingEntries() {
        let system = TestData.extensionRecord()
        let kernel = TestData.kernelExtensionRecord()
        let plugin = TestData.pluginRecord()
        let previous = TestData.extensionSnapshot([system, kernel, plugin])
        let current = TestData.extensionSnapshot([], at: later).addingExtensions(
            ExtensionContribution(records: [plugin], incompleteGroups: [.systemExtensions]), carryingForwardFrom: previous
        )
        #expect(Set(current.extensions.map(\.id)) == [system.id, plugin.id])
        #expect(events(previous, current) == ["removed:\(kernel.id)"])
    }

    /// Ein nicht auswertbares Bundle oder ein nicht lesbarer Ordner hält nur die Einträge an oder unter diesem Pfad.
    @Test func incompletePathCarriesOnlyEntriesBelowIt() {
        let broken = TestData.pluginRecord("/Library/Audio/Plug-Ins/HAL/Broken.driver")
        let inUnreadableFolder = TestData.pluginRecord("/Library/CoreMediaIO/Plug-Ins/DAL/Cam.plugin", kind: .videoPlugin)
        let removed = TestData.pluginRecord("/Library/Audio/Plug-Ins/HAL/Removed.driver")
        let previous = TestData.extensionSnapshot([broken, inUnreadableFolder, removed])
        let current = TestData.extensionSnapshot([], at: later).addingExtensions(
            ExtensionContribution(incompletePaths: ["/Library/Audio/Plug-Ins/HAL/Broken.driver", "/Library/CoreMediaIO/Plug-Ins/DAL"]),
            carryingForwardFrom: previous
        )
        #expect(Set(current.extensions.map(\.id)) == [broken.id, inUnreadableFolder.id])
        #expect(events(previous, current) == ["removed:\(removed.id)"])
    }

    /// Wieder gesehene Einträge behalten „erstmals gesehen“ und – bis zur nächsten Zuordnung – ihre App.
    @Test func reseenEntriesKeepFirstSeenAndOwner() {
        let owner = ExtensionOwnership.app(path: "/Applications/Vendor.app", evidence: .bundleID)
        let previous = TestData.extensionSnapshot([TestData.extensionRecord(owner: owner)])
        let current = TestData.extensionSnapshot([], at: later).addingExtensions(
            ExtensionContribution(records: [TestData.extensionRecord(version: "2.0", firstSeenAt: later)]),
            carryingForwardFrom: previous
        )
        #expect(current.extensions.map(\.firstSeenAt) == [TestData.date])
        #expect(current.extensions.map(\.owner) == [owner])
        #expect(current.extensions.map(\.version) == ["2.0"])
    }

    @Test func carryingForwardIsIdempotent() {
        let previous = TestData.extensionSnapshot([TestData.extensionRecord(), TestData.pluginRecord()])
        let contribution = ExtensionContribution(records: [TestData.pluginRecord()], incompleteGroups: [.systemExtensions])
        let once = TestData.extensionSnapshot([], at: later).addingExtensions(contribution, carryingForwardFrom: previous)
        let twice = once.addingExtensions(ExtensionContribution(), carryingForwardFrom: previous)
        #expect(once == twice)
    }

    // MARK: Zuordnung zur App

    @Test func ownersFollowTheAppIndex() {
        let embedding = TestData.installedApp("Vendor", bundleID: "com.vendor.app",
                                              signing: SigningInfo(kind: .developerID, teamID: "TEAMSYS001", isNotarized: true))
        let index = AppExtensionIndex(apps: [embedding], embedded: [embedding.path: ["com.vendor.filter"]], unreadable: [])
        let snapshot = TestData.extensionSnapshot([TestData.extensionRecord(), TestData.pluginRecord()], apps: [embedding])
            .assigningExtensionOwners(index)
        #expect(snapshot.extensions.map(\.owner) == [.app(path: embedding.path, evidence: .bundleID), .missing])
    }

    /// Ist das App-Inventar nur eingeschränkt gelesen (nicht lesbarer Ordner, Signatur nicht geprüft), ist „App fehlt“
    /// nicht belegt.
    @Test func limitedAppInventoryNeverReportsMissingOwners() {
        let index = AppExtensionIndex(apps: [], embedded: [:], unreadable: [])
        var snapshot = TestData.extensionSnapshot([TestData.pluginRecord()])
        snapshot.sourceLimitations = [SourceLimitation(source: .apps, message: "Ordner nicht lesbar")]
        #expect(snapshot.assigningExtensionOwners(index).extensions.map(\.owner) == [.unclear(candidates: [])])
        snapshot.sourceLimitations = [SourceLimitation(source: .extensions, message: "anderes")]
        #expect(snapshot.assigningExtensionOwners(index).extensions.map(\.owner) == [.missing])
    }
}
