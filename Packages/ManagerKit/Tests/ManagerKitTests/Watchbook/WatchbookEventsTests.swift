import Foundation
import Testing
@testable import ManagerKit

/// Änderungen aus dem Verlauf als Marken im Wachbuch (TM-12.4, #382).
@Suite struct WatchbookEventsTests {
    private typealias Fixtures = WatchbookFixtures
    private let start = WatchbookFixtures.dayStart
    private let uid = WatchbookFixtures.currentUID

    private func entry(_ kind: ChangeEvent.Kind, _ subject: ChangeSubject, after offset: TimeInterval = 0,
                       previous: ChangeSubject? = nil) -> HistoryEvent {
        let event = ChangeEvent(kind: kind, before: kind == .added ? nil : previous ?? subject,
                                after: kind == .removed ? nil : subject, detectedAt: start.addingTimeInterval(offset))
        return HistoryEvent(id: UUID(), event: event, isRead: false)
    }

    private func everything(in store: WatchbookStore) -> [WatchbookEvent] {
        store.records(in: Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 4_000_000_000)).events
    }

    // MARK: Abbildung je Quelle

    /// Zeitpunkt, Quelle, Kurztext und Verweis: Die Marke trägt die ID des Verlaufseintrags.
    @Test func autostartChangeBecomesAMark() throws {
        let history = entry(.added, .autostartItem(TestData.item("com.example.updater")), after: 42)
        let mark = try #require(WatchbookChangeMarks.mark(for: history, currentUID: uid))
        #expect(mark.id == history.id)
        #expect(mark.kind == .change)
        #expect(mark.type == WatchbookChangeSource.autostart.rawValue)
        #expect(WatchbookChangeSource(event: mark) == .autostart)
        #expect(mark.start == start.addingTimeInterval(42))
        #expect(mark.end == mark.start)
        #expect(mark.tone == nil)
        #expect(mark.subject == nil)
        #expect(mark.summary == "Neuer Autostart-Eintrag: com.example.updater")
    }

    @Test func networkServiceChangeNamesOwnProgramAndPort() throws {
        let history = entry(.added, .networkListener(TestData.listener(uid: uid, port: 3000)))
        let mark = try #require(WatchbookChangeMarks.mark(for: history, currentUID: uid))
        #expect(mark.type == WatchbookChangeSource.networkService.rawValue)
        #expect(mark.subject == .program("node"))
        #expect(mark.summary == "Neuer Netzwerkdienst: node, Port 3000/tcp")
    }

    /// Programme anderer Benutzer heißen „Andere Konten“ (Spec §4.5) – auch im Kurztext.
    @Test func networkServiceOfAnotherAccountStaysAnonymous() throws {
        let history = entry(.added, .networkListener(TestData.listener("/Users/other/bin/secret-tool", uid: 502)))
        let mark = try #require(WatchbookChangeMarks.mark(for: history, currentUID: uid))
        #expect(mark.subject == .otherAccounts)
        #expect(!mark.summary.contains("secret-tool"))
        #expect(!mark.summary.contains("/Users/other"))
        #expect(mark.summary == "Neuer Netzwerkdienst: Andere Konten, Port 3000/tcp")
    }

    /// Vermutliche Clients (WebRTC im Browser) kommen und gehen ständig; sie ergeben keine Marke.
    @Test func benignClientUDPIsNoMark() {
        let browser = TestData.listener("/Applications/Browser.app/Contents/MacOS/Browser", transport: .udp, port: nil,
                                        signing: TestData.developerSigning)
        #expect(WatchbookChangeMarks.mark(for: entry(.added, .networkListener(browser)), currentUID: uid) == nil)
    }

    @Test func appChangeNamesAppWithVersion() throws {
        let old = TestData.installedApp("Zoom", version: "6.0")
        let new = TestData.installedApp("Zoom", version: "6.1")
        let history = entry(.modified, .installedApp(new), previous: .installedApp(old))
        let mark = try #require(WatchbookChangeMarks.mark(for: history, currentUID: uid))
        #expect(mark.type == WatchbookChangeSource.app.rawValue)
        #expect(mark.subject == .program("Zoom"))
        #expect(mark.summary == "App aktualisiert: Zoom 6.1 (600)")
    }

    /// Agenten: keine Befehlszeilen und keine Pfade (Spec §4.5), nur Name und Ort.
    @Test func agentChangesNameNoCommandOrPath() throws {
        let server = TestData.mcpServer("filesystem", transport: .local(command: "npx", arguments: ["-y", "secret-pkg"]))
        let serverMark = try #require(WatchbookChangeMarks.mark(for: entry(.added, .mcpServer(server)),
                                                               currentUID: uid))
        #expect(serverMark.type == WatchbookChangeSource.agent.rawValue)
        #expect(serverMark.summary == "Neuer MCP-Server: „filesystem“ in Claude Desktop")
        #expect(!serverMark.summary.contains("npx"))
        #expect(!serverMark.summary.contains("/Users"))

        let approval = TestData.autoApproval()
        let approvalMark = try #require(WatchbookChangeMarks.mark(for: entry(.added, .agentAutoApproval(approval)),
                                                                 currentUID: uid))
        #expect(approvalMark.type == WatchbookChangeSource.agent.rawValue)
        #expect(approvalMark.summary == "Automatische Freigabe aktiv: Claude Code, permissions.defaultMode")
        #expect(!approvalMark.summary.contains("/Users"))
    }

    /// Erweiterungen (TM-13.3): Name und Art, ohne Pfad und ohne Verursacher – eine Erweiterung ist kein Programm.
    @Test func extensionChangeBecomesAMarkWithoutPath() throws {
        let plugin = TestData.pluginRecord("/Users/test/Library/Audio/Plug-Ins/HAL/Vendor.driver")
        let mark = try #require(WatchbookChangeMarks.mark(for: entry(.added, .extensionRecord(plugin)), currentUID: uid))
        #expect(mark.type == WatchbookChangeSource.extensionRecord.rawValue)
        #expect(mark.type == "change.extension")
        #expect(WatchbookChangeSource(event: mark) == .extensionRecord)
        #expect(mark.subject == nil)
        #expect(mark.summary == "Neue Erweiterung: Vendor Audio (Audio-Plug-in)")
        #expect(!mark.summary.contains("/Users"))
    }

    /// Nur Quellen, die zur Frage „Was war los?“ beitragen: Berechtigungen, Sicherheitsprüfungen und eigene Aktionen
    /// des Task-Managers bleiben im Verlauf.
    @Test func otherSourcesAreNoMarks() {
        #expect(WatchbookChangeMarks.mark(for: entry(.added, .grant(TestData.grant())), currentUID: uid) == nil)
        let check = TestData.securityCheck(TestData.firewallOn, state: .good)
        #expect(WatchbookChangeMarks.mark(for: entry(.modified, .securityCheck(check)), currentUID: uid) == nil)
    }

    /// Fremde Namen bleiben einzeilig und begrenzt (Spec §4.5).
    @Test func foreignNamesAreSingleLineAndLimited() throws {
        let label = "com.example.\nzweite Zeile" + String(repeating: "x", count: 500)
        let mark = try #require(WatchbookChangeMarks.mark(for: entry(.added, .autostartItem(TestData.item(label))),
                                                         currentUID: uid))
        #expect(!mark.summary.contains("\n"))
        #expect(mark.summary.count <= WatchbookChangeMarks.maximumNameLength + "Neuer Autostart-Eintrag: ".count)
    }

    // MARK: Befund „neuer aus dem Netz erreichbarer Dienst“

    @Test func exposedServiceAlsoBecomesAFinding() throws {
        let history = entry(.added, .networkListener(TestData.listener(uid: uid, port: 3000)), after: 60)
        let events = WatchbookChangeMarks.events(for: [history], currentUID: uid)
        #expect(events.count == 2)
        let finding = try #require(events.first { $0.kind == .finding })
        #expect(finding.type == SystemFinding.Kind.exposedService.rawValue)
        #expect(finding.start == start.addingTimeInterval(60))
        #expect(finding.end == finding.start)
        #expect(finding.subject == .program("node"))
        #expect(events.contains { $0.kind == .change && $0.id == history.id })
    }

    // MARK: Nachtrag und Dubletten

    /// Änderungen aus der Zeit vor dem Einschalten werden nachgetragen – nur Marken, keine Messwerte.
    @Test func backfillAddsMarksFromHistoryWithoutPoints() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let now = start.addingTimeInterval(3_600)
            let history = [
                entry(.added, .autostartItem(TestData.item("com.example.a")), after: 600),
                entry(.added, .installedApp(TestData.installedApp("Zoom")), after: 1_200),
            ]
            let recorded = try journal.recordChanges(history, currentUID: uid, now: now)
            #expect(recorded.map(\.id) == history.map(\.id))
            try journal.flush(now: now)
            let records = store.records(in: start..<now)
            #expect(records.points.isEmpty)
            #expect(records.minutes.isEmpty)
            #expect(records.events.map(\.id) == history.map(\.id))
        }
    }

    /// Erneuter Scan bzw. erneuter Nachtrag: keine doppelten Marken – weder geschrieben noch gepuffert.
    @Test func repeatedBackfillWritesNoDuplicates() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let now = start.addingTimeInterval(3_600)
            let history = [
                entry(.added, .autostartItem(TestData.item("com.example.a")), after: 600),
                entry(.added, .networkListener(TestData.listener(uid: uid)), after: 900),
            ]
            #expect(try journal.recordChanges(history, currentUID: uid, now: now).count == 3)
            // Noch gepuffert: Ein zweiter Lauf erkennt sie trotzdem.
            #expect(try journal.recordChanges(history, currentUID: uid, now: now).isEmpty)
            try journal.flush(now: now)
            let size = try Fixtures.size(of: Fixtures.url(of: Fixtures.day, in: store))
            // Geschrieben: Ein dritter Lauf, auch mit einem neuen Eintrag, hängt nur diesen an.
            let later = entry(.removed, .autostartItem(TestData.item("com.example.a")), after: 1_800)
            #expect(try journal.recordChanges(history + [later], currentUID: uid, now: now).map(\.id) == [later.id])
            try journal.flush(now: now)
            #expect(try Fixtures.size(of: Fixtures.url(of: Fixtures.day, in: store)) > size)
            let events = everything(in: store)
            #expect(events.count == 4)
            #expect(Set(events.map(\.id)).count == 4)
        }
    }

    /// Älter als die Aufbewahrung des Wachbuchs: kein Nachtrag (die Wartung würde ihn sofort wieder löschen).
    @Test func backfillSkipsChangesBeyondRetention() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let now = start.addingTimeInterval(WatchbookStore.retention + 3_600)
            let old = entry(.added, .autostartItem(TestData.item("com.example.old")), after: 0)
            let recent = entry(.added, .autostartItem(TestData.item("com.example.new")), after: WatchbookStore.retention)
            let recorded = try journal.recordChanges([old, recent], currentUID: uid, now: now)
            #expect(recorded.map(\.id) == [recent.id])
        }
    }

    /// Der Nachtrag liest den Verlauf ab dem Beginn der Aufbewahrung.
    @Test func historySinceRetentionStartComesFromTheStore() async throws {
        let store = try SwiftDataSnapshotStore.inMemory()
        let now = start.addingTimeInterval(WatchbookStore.retention + 3_600)
        let old = ChangeEvent(kind: .added, before: nil, after: .autostartItem(TestData.item("old")), detectedAt: start)
        let recent = ChangeEvent(kind: .removed, before: .autostartItem(TestData.item("new")), after: nil,
                                 detectedAt: now.addingTimeInterval(-60))
        _ = try await store.record(TestData.snapshot(), events: [old, recent])
        let history = try await WatchbookChangeMarks.history(from: store, now: now)
        #expect(history.map(\.event) == [recent])
    }

    // MARK: Fensterabfrage

    /// Ereignisse ±5 min um einen Zeitpunkt (TM-12.6), geschriebene wie gepufferte, aufsteigend nach Beginn.
    @Test func eventsAroundATimeCoverFiveMinutesEitherSide() throws {
        try Fixtures.withStore { store in
            let journal = WatchbookJournal(store: store)
            let time = start.addingTimeInterval(7_200)
            let before = Fixtures.event(.change, start: time.addingTimeInterval(-300), end: time.addingTimeInterval(-300))
            let tooEarly = Fixtures.event(.change, start: time.addingTimeInterval(-301),
                                          end: time.addingTimeInterval(-301))
            let after = Fixtures.event(.change, start: time.addingTimeInterval(300), end: time.addingTimeInterval(300))
            let tooLate = Fixtures.event(.change, start: time.addingTimeInterval(301), end: time.addingTimeInterval(301))
            // Ein Befund, der lange vorher begann und noch läuft, gehört dazu.
            let running = Fixtures.event(start: time.addingTimeInterval(-3_600), end: nil)
            for event in [before, tooEarly, running] { try journal.record(event, now: start) }
            try journal.flush(now: start)
            for event in [after, tooLate] { try journal.record(event, now: start) }
            #expect(journal.pendingEvents.count == 2)
            let around = journal.events(around: time)
            #expect(around.map(\.id) == [running.id, before.id, after.id])
            #expect(WatchbookEvent.neighborhood == 300)
        }
    }

    /// Über Mitternacht (UTC) hinweg: Das Fenster liest beide Tage.
    @Test func eventsAroundMidnightSpanTwoDays() throws {
        try Fixtures.withStore { store in
            let midnight = Fixtures.day.end
            let late = Fixtures.event(.change, start: midnight.addingTimeInterval(-120),
                                      end: midnight.addingTimeInterval(-120))
            let early = Fixtures.event(.change, start: midnight.addingTimeInterval(120),
                                       end: midnight.addingTimeInterval(120))
            try store.append(points: [], events: [late, early])
            #expect(store.events(around: midnight).map(\.id) == [late.id, early.id])
        }
    }
}
