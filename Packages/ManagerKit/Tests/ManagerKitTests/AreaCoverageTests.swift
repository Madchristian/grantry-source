import Foundation
import Testing
@testable import ManagerKit
import TestSupport

/// Scan-Abdeckung je Inventarbereich (#142): Zustand, Zeitpunkt, Grund, nächster Schritt und keine Entwarnung bei Lücken.
@Suite struct AreaCoverageTests {
    private static let calendar = TestData.utcCalendar
    private static let now = TestData.date
    private static let yesterday = TestData.date - TestData.day

    private static func coverage(_ area: InventoryArea, _ snapshot: Snapshot) -> AreaCoverage {
        AreaCoverage(area: area, snapshot: snapshot)
    }

    // MARK: - Zustände

    @Test func fullyDeliveredAreaIsCurrentWithItsDeliveryTime() throws {
        var snapshot = TestData.snapshot()
        snapshot.lastDeliveryBySource = [.launchd: Self.now, .btm: Self.now - 60]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.state == .current)
        #expect(coverage.isComplete)
        #expect(coverage.checkedAt == Self.now - 60)
        #expect(coverage.tone == .positive)
        #expect(coverage.statusLine(now: Self.now, calendar: Self.calendar) == "Aktuell · Geprüft heute, 14:12")
        #expect(coverage.reasons(now: Self.now, calendar: Self.calendar).isEmpty)
        #expect(coverage.emptyListCaveat == nil)
        #expect(coverage.nextStep(missingSetupSteps: [.fullDiskAccess, .helper]) == nil)
    }

    /// Ältere Snapshots ohne Lieferzeitpunkte: der Scan selbst.
    @Test func withoutDeliveryTimesTheSnapshotTimeCounts() {
        #expect(Self.coverage(.permissions, TestData.snapshot(at: Self.yesterday)).checkedAt == Self.yesterday)
    }

    /// Ausgefallene Quelle mit früherer Lieferung: Ihre Einträge sind fortgeschrieben – letzter bekannter Stand mit
    /// Zeitpunkt und Grund, keine Entwarnung.
    @Test func failedSourceShowsLastKnownStateWithTimeAndReason() {
        var snapshot = TestData.snapshot(errors: [SourceError(source: .btm, message: "Helper nicht erreichbar")])
        snapshot.lastDeliveryBySource = [.launchd: Self.now, .btm: Self.yesterday]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.state == .lastKnown)
        #expect(coverage.checkedAt == Self.yesterday)
        #expect(coverage.tone == .warning)
        #expect(coverage.headline == "Letzter bekannter Stand")
        #expect(coverage.timeText(now: Self.now, calendar: Self.calendar) == "Stand von gestern, 14:13")
        #expect(coverage.reasons(now: Self.now, calendar: Self.calendar) == [
            "Hintergrundobjekte: nicht gelesen (Helper nicht erreichbar) – angezeigt wird der Stand von gestern, 14:13",
        ])
        #expect(coverage.emptyListCaveat != nil)
        #expect(!coverage.isComplete)
    }

    @Test func failedSourceWithoutKnownDeliveryTimeSaysSo() {
        let snapshot = TestData.snapshot(errors: [SourceError(source: .launchd, message: "x")])
        let coverage = Self.coverage(.autostart, snapshot)
        #expect(coverage.state == .lastKnown)
        #expect(coverage.checkedAt == nil)
        #expect(coverage.timeText(now: Self.now) == "Stand unbekannt")
        #expect(coverage.reasons(now: Self.now) == ["launchd: nicht gelesen (x) – angezeigt wird der letzte bekannte Stand"])
    }

    /// Eine Quelle, die noch nie geliefert hat, hat keinen Stand: Liefern die übrigen, ist der Bereich nur teilweise
    /// geprüft.
    @Test func neverDeliveredSourceBesideDeliveredOneIsPartial() {
        let snapshot = TestData.snapshot(errors: [SourceError(source: .tccSystem, message: "kein Zugriff")],
                                         baseline: [.tccUser, .launchd, .btm])
        let coverage = Self.coverage(.permissions, snapshot)
        #expect(coverage.state == .partial)
        #expect(coverage.reasons(now: Self.now) == [
            "Berechtigungen (System): nicht gelesen (kein Zugriff) – noch kein bekannter Stand",
        ])
    }

    /// Hat keine Quelle des Bereichs je geliefert, ist er nicht geprüft – eine leere Liste ist keine Entwarnung.
    @Test func areaWithoutAnyDeliveryIsUnread() {
        let snapshot = TestData.snapshot(errors: [SourceError(source: .networkListeners, message: "lsof fehlt")])
        let coverage = Self.coverage(.network, snapshot)
        #expect(coverage.state == .unread)
        #expect(coverage.checkedAt == nil)
        #expect(coverage.tone == .critical)
        #expect(coverage.statusLine(now: Self.now) == "Nicht geprüft · Noch nie gelesen")
        #expect(coverage.reasons(now: Self.now) == ["nicht gelesen (lsof fehlt) – noch kein bekannter Stand"])
        #expect(coverage.emptyListCaveat == "Nicht vollständig geprüft – eine leere Liste ist hier keine Entwarnung.")
    }

    /// Einschränkungen und fortgeschriebene Autostart-Einträge (#139) ergeben „teilweise geprüft“ samt Umfang.
    @Test func limitationsAndOutdatedItemsArePartialWithScope() {
        var outdated = TestData.item("com.example.old")
        outdated.lastVerifiedAt = Self.yesterday
        var snapshot = TestData.snapshot(items: [outdated, TestData.item("com.example.new"), TestData.item("com.example.gone")])
        snapshot.items(markingOutdated: ["com.example.gone"], at: Self.yesterday)
        snapshot.sourceLimitations = [
            SourceLimitation(source: .launchd, message: "Plist /Users/test/Library/LaunchAgents/a.plist nicht auswertbar"),
            SourceLimitation(source: .apps, message: "fremd"),
        ]
        let coverage = Self.coverage(.autostart, snapshot)

        #expect(coverage.state == .partial)
        #expect(coverage.outdatedRecordCount == 2)
        #expect(coverage.reasons(now: Self.now, home: "/Users/test") == [
            "launchd: Plist ~/Library/LaunchAgents/a.plist nicht auswertbar",
            "2 Einträge zeigen einen alten Stand; Aktionen dafür sind bis zum erneuten Lesen gesperrt.",
        ])
        #expect(coverage.headline == "Teilweise geprüft")
        // Kaputte Plist und alter Stand behebt kein Scan: kein „Erneut prüfen“.
        #expect(coverage.nextStep(missingSetupSteps: []) == nil)
    }

    @Test func outdatedItemsAloneMakeAutostartPartial() {
        var outdated = TestData.item()
        outdated.lastVerifiedAt = Self.yesterday
        let coverage = Self.coverage(.autostart, TestData.snapshot(items: [outdated]))
        #expect(coverage.state == .partial)
        #expect(coverage.reasons(now: Self.now).last
            == "1 Eintrag zeigt einen alten Stand; Aktionen dafür sind bis zum erneuten Lesen gesperrt.")
        #expect(Self.coverage(.permissions, TestData.snapshot(items: [outdated])).state == .current)
    }

    // MARK: - Positive Evidenz (Codex-Review)

    /// Ohne Fehler und ohne Liefernachweis – etwa ein älterer Snapshot vor dem ersten Scan mit Agenten- und
    /// Netzwerkquelle – ist ein Bereich nie „aktuell“, sondern nicht geprüft; eine leere Liste ist keine Entwarnung.
    @Test func areaWithoutDeliveryEvidenceIsUnreadNotCurrent() {
        let old = TestData.snapshot(baseline: [.tccUser, .tccSystem, .launchd, .btm])
        for area in [InventoryArea.agents, .network, .apps, .security] {
            let coverage = Self.coverage(area, old)
            #expect(coverage.state == .unread, "\(area)")
            #expect(!coverage.isComplete, "\(area)")
            #expect(coverage.emptyListCaveat != nil, "\(area)")
            #expect(coverage.reasons(now: Self.now) == ["Noch nicht gelesen – kein bekannter Stand"], "\(area)")
        }
    }

    /// Fehlt der Nachweis nur für eine von mehreren Quellen, ist der Bereich teilweise geprüft – mit Lücke und dem
    /// passenden Einrichtungsschritt.
    @Test func missingSecondSourceIsPartialWithGap() {
        var snapshot = TestData.snapshot(baseline: [])
        snapshot.lastDeliveryBySource = [.tccUser: Self.now]
        let coverage = Self.coverage(.permissions, snapshot)
        #expect(coverage.state == .partial)
        #expect(coverage.checkedAt == Self.now)
        #expect(coverage.reasons(now: Self.now) == ["Berechtigungen (System): noch nicht gelesen – kein bekannter Stand"])
        #expect(coverage.nextStep(missingSetupSteps: [.fullDiskAccess]) == .setUp(.fullDiskAccess))
    }

    /// Ein Lieferzeitpunkt allein ist Nachweis genug (auch ohne Baseline-Eintrag).
    @Test func deliveryTimeCountsAsEvidence() {
        var snapshot = TestData.snapshot(baseline: [])
        snapshot.lastDeliveryBySource = [.agents: Self.now]
        #expect(Self.coverage(.agents, snapshot).state == .current)
    }

    /// Eine ausgefallene Sicherheitsprüfung (Quelle liefert trotzdem) wird zur Einschränkung mit Name und Grund – der
    /// Bereich ist teilweise geprüft, auch wenn alle Prüfungen ausfallen.
    @Test func unknownSecurityChecksAreCoverageGaps() async throws {
        let sip = FixedSecurityProbe(kinds: [.sip], result: .failure(TestFailure()))
        let fileVault = FixedSecurityProbe(kinds: [.fileVault], result: .success([.fileVault(.on)]))
        let contribution = try await SecurityPostureSource(probes: [fileVault, sip], now: { Self.now }).collect()
        #expect(contribution.limitations.isEmpty)
        #expect(contribution.retryableLimitations == ["Systemintegritätsschutz (SIP) nicht geprüft: kaputt"])

        let snapshot = try await ScanCoordinator(sources: [SecurityPostureSource(probes: [fileVault, sip])],
                                                 now: { Self.now }).scan()
        let coverage = Self.coverage(.security, snapshot)
        #expect(coverage.state == .partial)
        #expect(coverage.reasons(now: Self.now) == ["Systemintegritätsschutz (SIP) nicht geprüft: kaputt"])
        #expect(coverage.nextStep(missingSetupSteps: []) == .rescan)

        let allFailed = try await SecurityPostureSource(probes: [sip], now: { Self.now }).collect()
        #expect(allFailed.retryableLimitations.count == 1)
        let complete = try await SecurityPostureSource(probes: [fileVault], now: { Self.now }).collect()
        #expect(complete.retryableLimitations.isEmpty)
    }

    // MARK: - Aktive Quellen (Codex-Review Runde 2)

    /// v1-Entscheidung „nur System-TCC“ über den echten Pfad `StandardSources.v5` → `ScanCoordinator` →
    /// `MonitoringState`/`PresentationInput`: Liefert die System-TCC-Quelle, sind die Berechtigungen aktuell – die
    /// Benutzer-TCC ist keine Lücke, nur ein ruhiger Hinweis ohne „Erneut prüfen“.
    @Test func permissionsAreCurrentWithSystemTCCOnlyFromStandardSources() async throws {
        try await ScratchDirectory.with { home in
            let sources = StandardSources.v5(
                btmProvider: StubBTMProvider(), resolver: StubAppResolver(), sockets: nil, fingerprinter: .ephemeral(),
                runner: MockCommandRunner(), apps: AppInventorySource(roots: []),
                agents: AgentConfigSource(catalog: TestData.userCatalog, home: home.path,
                                          inspector: RecordingSigningInspector(result: .unknown))
            )
            let active = ScanCoordinator(sources: sources).sourceIDs
            #expect(!active.contains(.tccUser))
            #expect(active.contains(.tccSystem))

            // Nur die System-TCC liefert (die übrigen Quellen sind hier nicht Gegenstand).
            let systemTCC = FixedSource(id: .tccSystem, result: .success(InventoryContribution(grants: [TestData.grant(scope: .system)])))
            let snapshot = try await ScanCoordinator(sources: [systemTCC], now: { Self.now }).scan()
            let state = MonitoringState(snapshot: snapshot, activeSources: active)
            let presentation = try #require(PresentationInput(state: state, recentAdditions: [])).make(now: Self.now)
            let permissions = try #require(presentation.coverage[.permissions])

            #expect(permissions.state == .current)
            #expect(permissions.isComplete)
            #expect(permissions.gaps.isEmpty)
            #expect(permissions.notes(now: Self.now) == ["Benutzerbezogene Berechtigungen werden nicht ausgewertet."])
            #expect(permissions.nextStep(missingSetupSteps: []) == nil)
        }
    }

    /// Fehler einer nicht aktiven Quelle (etwa aus einem älteren Snapshot) zählen nicht; Bereiche ohne aktive Quelle
    /// fehlen in der Übersicht.
    @Test func inactiveSourcesAreIgnored() {
        var snapshot = TestData.snapshot(errors: [SourceError(source: .tccUser, message: "alt")])
        snapshot.lastDeliveryBySource = [.tccSystem: Self.now]
        let active: Set<SourceID> = [.tccSystem, .launchd, .btm]
        let overview = CoverageOverview(snapshot: snapshot, activeSources: active)
        #expect(overview[.permissions]?.state == .current)
        #expect(overview.areas.map(\.area) == [.permissions, .autostart])
        #expect(overview[.network] == nil)
    }

    /// Nur Zwischenmessungen, keine vollständige Lieferung und keine erklärende Einschränkung: nie „aktuell“.
    @Test func interimOnlyDeliveryIsPartial() {
        var snapshot = TestData.snapshot(baseline: [.networkListeners])
        snapshot.lastInterimDeliveryBySource = [.networkListeners: Self.now]
        let coverage = Self.coverage(.network, snapshot)
        #expect(coverage.state == .partial)
        #expect(coverage.reasons(now: Self.now, calendar: Self.calendar)
            == ["Bisher nur eigene Dienste gemessen (heute, 14:13) – noch keine vollständige Prüfung"])
        #expect(coverage.notes(now: Self.now).isEmpty)
        #expect(coverage.nextStep(missingSetupSteps: []) == .rescan)

        // Erklärt eine Einschränkung die Lücke schon, kommt keine zweite Zeile dazu.
        snapshot.sourceLimitations = [SourceLimitation(source: .networkListeners, message: "nur eigene", isRetryable: true)]
        #expect(Self.coverage(.network, snapshot).reasons(now: Self.now) == ["nur eigene"])
    }

    /// „Erneut prüfen“ nur, wenn ein Scan die Lücke schließen kann.
    @Test func rescanOnlyForRetryableGaps() {
        var snapshot = TestData.snapshot(baseline: [.agents, .apps])
        snapshot.sourceLimitations = [
            SourceLimitation(source: .agents, message: "Projekte auf Netzlaufwerk /Volumes/x nicht gelesen"),
            SourceLimitation(source: .apps, message: "Signatur von 1 App nicht geprüft", isRetryable: true),
        ]
        #expect(Self.coverage(.agents, snapshot).nextStep(missingSetupSteps: []) == nil)
        #expect(Self.coverage(.apps, snapshot).nextStep(missingSetupSteps: []) == .rescan)
        let unread = Self.coverage(.network, snapshot)
        #expect(unread.state == .unread)
        #expect(unread.nextStep(missingSetupSteps: []) == .rescan)
    }

    @Test func retryableFlagSurvivesEncodingAndDefaultsToFalse() throws {
        let limitation = SourceLimitation(source: .apps, message: "x", isRetryable: true)
        #expect(try JSONDecoder().decode(SourceLimitation.self, from: JSONEncoder().encode(limitation)) == limitation)
        let old = Data(#"{"source":"apps","message":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(SourceLimitation.self, from: old).isRetryable == false)
    }

    // MARK: - Nächster Schritt

    @Test func missingSetupStepOfAnAffectedSourceComesFirst() {
        let snapshot = TestData.snapshot(errors: [SourceError(source: .tccSystem, message: "kein Zugriff")])
        let coverage = Self.coverage(.permissions, snapshot)
        #expect(coverage.nextStep(missingSetupSteps: [.fullDiskAccess]) == .setUp(.fullDiskAccess))
        #expect(coverage.nextStep(missingSetupSteps: [.helper]) == .rescan)
        #expect(coverage.nextStep(missingSetupSteps: []) == .rescan)
        #expect(CoverageNextStep.setUp(.fullDiskAccess).title == "Festplattenvollzugriff erteilen …")
        #expect(CoverageNextStep.setUp(.helper).title == "Einrichtung öffnen …")
        #expect(CoverageNextStep.rescan.title == "Erneut prüfen")
    }

    @Test func limitedNetworkWithoutHelperOffersSetup() {
        var snapshot = TestData.snapshot(baseline: [.networkListeners])
        snapshot.sourceLimitations = [SourceLimitation(source: .networkListeners, message: "nur eigene")]
        #expect(Self.coverage(.network, snapshot).nextStep(missingSetupSteps: [.helper]) == .setUp(.helper))
    }

    // MARK: - Übersicht und Texte

    @Test func overviewCoversAllAreasAndListsIncompleteWorstFirst() {
        var snapshot = TestData.snapshot(errors: [SourceError(source: .btm, message: "x")],
                                         baseline: TestData.allSources.union([.apps, .agents]))
        snapshot.sourceLimitations = [SourceLimitation(source: .apps, message: "y")]
        snapshot.sourceErrors.append(SourceError(source: .agents, message: "z"))
        let overview = CoverageOverview(snapshot: snapshot)

        #expect(overview.areas.map(\.area) == InventoryArea.allCases)
        // Netzwerk und Sicherheit ohne Liefernachweis: nicht geprüft, schlechtester Zustand zuerst.
        #expect(overview.incomplete.map(\.area) == [.network, .security, .autostart, .agents, .apps])
        #expect(overview[.autostart]?.summaryLine(now: Self.now) == "Autostart: Letzter bekannter Stand · Stand unbekannt")
    }

    @Test func everySourceBelongsToExactlyOneArea() {
        let sources: [SourceID] = [.tccUser, .tccSystem, .launchd, .btm, .securityPosture, .apps, .networkListeners, .agents]
        for source in sources {
            #expect(InventoryArea.allCases.count { $0.sources.contains(source) } == 1, "\(source)")
        }
        #expect(SourceID.agents.displayName == "Agenten-Konfigurationen")
    }

    @Test func accessibilityLabelNamesAreaStateAndTime() {
        var snapshot = TestData.snapshot()
        snapshot.lastDeliveryBySource = [.tccUser: Self.now, .tccSystem: Self.now]
        #expect(Self.coverage(.permissions, snapshot).accessibilityLabel(now: Self.now, calendar: Self.calendar)
            == "Abdeckung Berechtigungen: Aktuell. Geprüft heute, 14:13.")
    }

    @Test func timestampsAreRelativeForTodayAndYesterday() {
        let calendar = Self.calendar
        #expect(CoverageTexts.timestamp(Self.now, now: Self.now, calendar: calendar) == "heute, 14:13")
        #expect(CoverageTexts.timestamp(Self.yesterday, now: Self.now, calendar: calendar) == "gestern, 14:13")
        #expect(CoverageTexts.timestamp(Self.now - 3 * TestData.day, now: Self.now, calendar: calendar) == "18. Sept., 14:13")
        #expect(CoverageTexts.timestamp(Self.now - 365 * TestData.day, now: Self.now, calendar: calendar)
            == "21. Sept. 2025, 14:13")
    }

    // MARK: - Lieferzeitpunkte

    /// Liefernde Quellen erhalten den Scanbeginn, ausgefallene behalten den letzten – auch im Teilscan.
    @Test func scanRecordsDeliveryTimesAndKeepsThemForFailedSources() async throws {
        let ok = FixedSource(id: .launchd, result: .success(InventoryContribution()))
        let failing = FixedSource(id: .btm, result: .failure(TestFailure()))
        let first = try await ScanCoordinator(
            sources: [ok, FixedSource(id: .btm, result: .success(InventoryContribution()))], now: { Self.yesterday }
        ).scan()
        #expect(first.lastDeliveryBySource == [.launchd: Self.yesterday, .btm: Self.yesterday])

        let second = try await ScanCoordinator(sources: [ok, failing], now: { Self.now }).scan(previous: first)
        #expect(second.lastDeliveryBySource == [.launchd: Self.now, .btm: Self.yesterday])
        #expect(AreaCoverage(area: .autostart, snapshot: second).state == .lastKnown)
        #expect(AreaCoverage(area: .autostart, snapshot: second).checkedAt == Self.yesterday)

        let partial = try await ScanCoordinator(sources: [ok, failing], now: { Self.now + 60 })
            .scan(previous: second, only: [.launchd])
        #expect(partial.lastDeliveryBySource == [.launchd: Self.now + 60, .btm: Self.yesterday])
        #expect(partial.isEquivalent(to: second))
    }

    @Test func deliveryTimesSurviveEncodingAndOldSnapshotsDecodeWithoutThem() throws {
        var snapshot = TestData.snapshot()
        snapshot.lastDeliveryBySource = [.launchd: Self.now]
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.lastDeliveryBySource == [.launchd: Self.now])

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "lastDeliveryBySource")
        let old = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.lastDeliveryBySource.isEmpty)
    }

    @Test func setupRecheckFollowsTheSourcesSetupDependency() {
        let complete = SetupChecklist(SetupStatus(fullDiskAccess: true, helper: .ready, notifications: .authorized,
                                                  launchAtLogin: .enabled))
        #expect(complete.shouldRecheck(after: TestData.snapshot(errors: [SourceError(source: .networkListeners, message: "x")])))
        #expect(!complete.shouldRecheck(after: TestData.snapshot(errors: [SourceError(source: .agents, message: "x")])))
    }
}

private struct StubBTMProvider: BTMDumpProviding {
    func dumpBTM() async throws -> String { "" }
}

/// Sicherheits-Probe mit festem Ergebnis.
private struct FixedSecurityProbe: SecurityProbe {
    let kinds: [SecurityCheckKind]
    let result: Result<[SecurityFacts], TestFailure>
    func read(now: Date) async throws -> [SecurityFacts] { try result.get() }
}

private extension Snapshot {
    /// Markiert die Autostart-Einträge mit den Labels `labels` als nur fortgeschrieben.
    mutating func items(markingOutdated labels: Set<String>, at date: Date) {
        autostartItems = autostartItems.map { item in
            var item = item
            if labels.contains(item.label) { item.lastVerifiedAt = date }
            return item
        }
    }
}
