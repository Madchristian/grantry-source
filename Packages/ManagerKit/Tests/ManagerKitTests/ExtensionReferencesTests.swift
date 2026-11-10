import Foundation
import Testing
@testable import ManagerKit

/// Querverweise der Erweiterungen (TM-13.6, #392): Abschnitt im App-Detail, Hinweis beim Entfernen einer App, Reste in
/// „Aufräumen“ und Zähler der Kachel „Auffällig“ in der Übersicht – mit Beispieldaten wie in der Vorschau.
struct ExtensionReferencesTests {
    static let vendor = TestData.installedApp("Vendor", bundleID: "com.vendor.app")
    static let other = TestData.installedApp("Other", bundleID: "com.other.app")
    static let owned = ExtensionOwnership.app(path: vendor.path, evidence: .bundleID)

    static let filter = TestData.extensionRecord(name: "Vendor Filter", owner: owned)
    static let driver = TestData.extensionRecord("com.vendor.dock", kind: .driver, name: "Vendor Dock", owner: owned)
    static let oldFilter = TestData.extensionRecord("com.vendor.old", name: "Alter Filter", state: .removalPending,
                                                    owner: owned)
    static let audio = ExtensionRecord(
        kind: .audioPlugin, bundleID: "com.vendor.audio", teamID: "TEAMPLUG01", name: "Vendor Audio", version: "1.0",
        buildVersion: "1.0", state: .installed,
        signing: SigningInfo(kind: .developerID, teamID: "TEAMPLUG01", isNotarized: true),
        path: "/Library/Audio/Plug-Ins/HAL/Vendor.driver", owner: .app(path: vendor.path, evidence: .teamID),
        firstSeenAt: TestData.date
    )
    static let guardian = TestData.extensionRecord("com.gone.guard", kind: .endpointSecurity, name: "Guard",
                                                   owner: .missing)
    static let orphanKext = ExtensionRecord(
        kind: .kernelExtension, bundleID: "com.gone.kext", teamID: "TEAMKEXT01", name: "Gone Kext", version: "1.0",
        buildVersion: "1.0", state: .notLoaded,
        signing: SigningInfo(kind: .developerID, teamID: "TEAMKEXT01", isNotarized: true),
        path: "/Library/Extensions/com.gone.kext.kext", owner: .missing, firstSeenAt: TestData.date
    )
    static let orphanPlugin = ExtensionRecord(
        kind: .audioPlugin, bundleID: "com.gone.audio", teamID: "TEAMGONE01", name: "Gone Audio", version: "1.0",
        buildVersion: "1.0", state: .installed,
        signing: SigningInfo(kind: .developerID, teamID: "TEAMGONE01", isNotarized: true),
        path: "/Library/Audio/Plug-Ins/HAL/Gone.driver", owner: .missing, firstSeenAt: TestData.date
    )
    static let pending = TestData.extensionRecord("com.gone.pending", name: "Ausgebaut", state: .removalPending,
                                                  owner: .missing)
    static let applePlugin = ExtensionRecord(
        kind: .audioPlugin, bundleID: "com.apple.audio.Plugin", teamID: nil, name: "Apple Audio", version: "1.0",
        buildVersion: "1.0", state: .installed, signing: SigningInfo(kind: .apple),
        path: "/Library/Audio/Plug-Ins/HAL/Apple.driver", owner: .missing, firstSeenAt: TestData.date
    )

    static func references(_ records: [ExtensionRecord]) -> ExtensionReferences {
        ExtensionReferences(records: records)
    }

    // MARK: App-Detail

    @Test func appDetailListsTheExtensionsTheAppBringsFromKernelOutward() {
        let references = Self.references([Self.audio, Self.guardian, Self.filter, Self.driver])
        #expect(references.owned(byAppAt: Self.vendor.path).map(\.id) == [Self.filter.id, Self.driver.id, Self.audio.id])
        #expect(references.owned(byAppAt: Self.other.path).isEmpty)
    }

    @Test func referenceNamesKindAndStateAndJumpsToTheRecord() throws {
        let reference = try #require(Self.references([Self.filter]).owned(byAppAt: Self.vendor.path).first)
        #expect(reference.id == Self.filter.id)
        #expect(reference.title == "Vendor Filter")
        #expect(reference.subtitle == "Netzwerkerweiterung · aktiv")
        #expect(reference.symbol == ExtensionKind.network.symbol)
    }

    @Test func foreignNamesStaySingleLineAndShort() throws {
        let long = TestData.extensionRecord(name: "Erste Zeile\nZweite Zeile " + String(repeating: "x", count: 200),
                                            owner: Self.owned)
        let reference = try #require(Self.references([long]).owned(byAppAt: Self.vendor.path).first)
        #expect(!reference.title.contains("\n"))
        #expect(reference.title.count <= ExtensionText.maximumNameLength)
    }

    @Test func detailOfTheAppCarriesItsExtensions() {
        let snapshot = TestData.extensionSnapshot([Self.filter, Self.guardian], apps: [Self.vendor, Self.other])
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: [], events: [], recentAdditions: [],
                                                     now: TestData.date)
        let detail = presentation.detail(for: Self.vendor, details: nil, now: TestData.date)
        #expect(detail.extensions.map(\.id) == [Self.filter.id])
        #expect(presentation.detail(for: Self.other, details: nil, now: TestData.date).extensions.isEmpty)
    }

    // MARK: Entfernen

    @Test func removalNamesSystemExtensionsAndThatARestartRemovesThem() throws {
        let note = try #require(Self.references([Self.filter, Self.driver]).removalNote(forAppAt: Self.vendor.path))
        #expect(note == "Die App bringt 2 Systemerweiterungen mit: Vendor Filter (Netzwerkerweiterung) und Vendor Dock "
            + "(Treiber). macOS schaltet sie ab, sobald die App im Papierkorb liegt; endgültig entfernt sie erst ein Neustart.")
    }

    @Test func removalNamesOtherExtensionsThatStayInstalled() throws {
        let note = try #require(Self.references([Self.filter, Self.audio]).removalNote(forAppAt: Self.vendor.path))
        #expect(note.hasPrefix("Die App bringt eine Systemerweiterung mit: Vendor Filter (Netzwerkerweiterung)."))
        #expect(note.hasSuffix("Nicht mit entfernt wird Vendor Audio (Audio-Plug-in); es bleibt installiert, „Aufräumen“ "
            + "zeigt es danach als Rest."))
    }

    @Test func removalWithoutExtensionsOrOnlyPendingOnesSaysNothing() {
        #expect(Self.references([Self.oldFilter, Self.guardian]).removalNote(forAppAt: Self.vendor.path) == nil)
        #expect(Self.references([]).removalNote(forAppAt: Self.vendor.path) == nil)
    }

    @Test func removalShortensLongLists() throws {
        let many = (1...5).map {
            TestData.extensionRecord("com.vendor.f\($0)", name: "Filter \($0)", owner: Self.owned)
        }
        let note = try #require(Self.references(many).removalNote(forAppAt: Self.vendor.path))
        #expect(note.hasPrefix("Die App bringt 5 Systemerweiterungen mit: Filter 1 (Netzwerkerweiterung), Filter 2 "
            + "(Netzwerkerweiterung), Filter 3 (Netzwerkerweiterung) und 2 weitere."))
    }

    // MARK: Aufräumen

    @Test func leftoversAreExtensionsWithoutAppButNoApplePlugins() {
        let references = Self.references([Self.filter, Self.orphanPlugin, Self.guardian, Self.orphanKext, Self.applePlugin])
        #expect(references.leftovers.map(\.id) == [Self.orphanKext.id, Self.guardian.id, Self.orphanPlugin.id])
    }

    @Test func leftoverSystemExtensionPointsToTheUninstallerAndSettings() throws {
        let leftover = try #require(Self.references([Self.guardian]).leftovers.first)
        #expect(leftover.note == "Grantry entfernt Systemerweiterungen nicht selbst: Deinstallieren lässt sie das "
            + "Programm des Herstellers, ausschalten die Systemeinstellungen.")
        #expect(leftover.actions == ExtensionSettingsLinks.systemExtensions.map { [.openSettings($0)] })
    }

    @Test func leftoverKernelExtensionOffersNoTrash() throws {
        let leftover = try #require(Self.references([Self.orphanKext]).leftovers.first)
        #expect(leftover.note == "Grantry entfernt Kernel-Erweiterungen nicht selbst: Deinstallieren lässt sie das "
            + "Programm des Herstellers.")
        #expect(!leftover.actions.contains(.moveToTrash))
        #expect(leftover.actions.contains(.revealInFinder(Self.orphanKext.path ?? "")))
    }

    @Test func leftoverPluginOffersTheTrashAfterConfirmation() throws {
        let leftover = try #require(Self.references([Self.orphanPlugin]).leftovers.first)
        #expect(leftover.actions == [.revealInFinder(Self.orphanPlugin.path ?? ""), .moveToTrash])
        #expect(leftover.note == "Gehört zu keiner App mehr. „In den Papierkorb …“ legt es nach Bestätigung über den "
            + "Finder weg; „Zurücklegen“ bleibt möglich.")
    }

    @Test func pendingLeftoverNeedsNothingButARestart() throws {
        let leftover = try #require(Self.references([Self.pending]).leftovers.first)
        #expect(leftover.note == "Wird beim nächsten Neustart entfernt – sonst ist nichts zu tun.")
        #expect(leftover.actions.isEmpty)
    }

    @Test func leftoversAreReadFromThePresentation() {
        let snapshot = TestData.extensionSnapshot([Self.orphanPlugin], apps: [Self.vendor])
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: [], events: [], recentAdditions: [],
                                                     now: TestData.date)
        #expect(presentation.extensions.leftovers.map(\.id) == [Self.orphanPlugin.id])
    }

    // MARK: Übersicht

    static func finding(_ record: ExtensionRecord, _ severity: RiskFinding.Severity) -> RiskFinding {
        RiskFinding(rule: .privilegedExtension, severity: severity, recordID: record.id, message: "Befund")
    }

    @Test func flaggedTileCountsExtensionsLikeTheOtherAreas() {
        let snapshot = TestData.extensionSnapshot([Self.filter, Self.guardian, Self.orphanKext, Self.applePlugin],
                                                  apps: [Self.vendor])
        let findings = [Self.finding(Self.guardian, .medium), Self.finding(Self.orphanKext, .high),
                        Self.finding(Self.filter, .low), Self.finding(Self.applePlugin, .medium)]
        let presentation = PresentationSnapshot.make(snapshot: snapshot, findings: findings, events: [],
                                                     recentAdditions: [], now: TestData.date)
        let metrics = presentation.metrics
        // Das ausgeblendete Plug-in von Apple zählt nicht – der Bereich zeigt es nicht.
        #expect(metrics.flagged.count(in: .extensions, for: .flagged) == 2)
        #expect(metrics.flagged.count(in: .extensions, for: .withFindings) == 3)
        #expect(metrics.flaggedCount == 2)
        #expect(metrics.hintCount == 1)
        #expect(presentation.flaggedArea == .extensions)
        #expect(presentation.highestSeverity == .high)
        #expect(FlaggedArea.extensions.title == "Erweiterungen")
    }

    @Test func otherAreasPointToFlaggedExtensions() throws {
        let camera = TestData.grant("kTCCServiceCamera")
        let snapshot = Snapshot(takenAt: TestData.date, grants: [camera], autostartItems: [], installedApps: [],
                                extensions: [Self.guardian], sourceErrors: [],
                                baselineSources: TestData.extensionSources)
        let presentation = PresentationSnapshot.make(
            snapshot: snapshot, findings: [Self.finding(Self.guardian, .medium),
                                           RiskFinding(rule: .orphan, severity: .medium, recordID: camera.id, message: "")],
            events: [], recentAdditions: [], now: TestData.date
        )
        let notice = try #require(presentation.metrics.flagged.notice(in: .permissions, filter: .flagged))
        #expect(notice.others.map(\.label) == ["Erweiterungen (1)"])
    }

    @Test func tileFilterOpensTheExtensionsWithTheMatchingFilter() {
        #expect(ExtensionFilter(findings: .flagged) == .findings)
        #expect(ExtensionFilter(findings: .withFindings) == .all)
        #expect(ExtensionFilter(findings: .all) == .all)
    }
}
