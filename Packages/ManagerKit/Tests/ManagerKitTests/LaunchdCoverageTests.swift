import Darwin
import Foundation
import Synchronization
import Testing
@testable import ManagerKit
import TestSupport

/// Unvollständige Abdeckung der launchd-Quelle (#139): Unlesbare Verzeichnisse und nicht auswertbare Plists belegen kein
/// Entfernen. Alles läuft in temporären Verzeichnissen mit Attrappen-Plists und gestubbtem launchctl.
@Suite struct LaunchdCoverageTests {
    private static let label = "com.example.coverage"
    private static var validPlist: [String: Any] { ["Label": label, "Program": "/bin/ls"] }

    private static func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    private static func runner() -> MockCommandRunner {
        let runner = MockCommandRunner()
        runner.stub("/bin/launchctl print-disabled gui/501", CommandResult(exitCode: 0, stdout: "\n\tdisabled services = {\n\t}\n"))
        runner.stub("/bin/launchctl print gui/501", CommandResult(exitCode: 0, stdout: "gui/501 = {\n\tservices = {\n\t}\n}\n"))
        return runner
    }

    private static func source(_ directory: URL, runner: MockCommandRunner = runner()) -> LaunchdSource {
        LaunchdSource(
            directories: [LaunchdDirectory(path: directory.path, kind: .launchAgent, domain: .user, launchctlDomain: "gui/501")],
            runner: runner, resolver: StubAppResolver()
        )
    }

    /// Scannt `directory` mit `previous` als Vorgänger, zum Zeitpunkt `date`; liefert Snapshot und Ereignisse.
    private static func scan(
        _ directory: URL, previous: Snapshot?, at date: Date
    ) async throws -> (snapshot: Snapshot, events: [ChangeEvent]) {
        let snapshot = try await ScanCoordinator(sources: [source(directory)], now: { date }).scan(previous: previous)
        return (snapshot, SnapshotDiffer().diff(from: previous, to: snapshot))
    }

    // MARK: - Fortschreiben statt Entfernen

    /// Die Reproduktion aus #139: Eine bekannte Plist wird durch ungültigen Text ersetzt. Ergebnis: eine Einschränkung,
    /// kein `removed`, der Eintrag bleibt mit dem Stand des letzten Lesens. Wird sie wieder gültig, ist der Eintrag
    /// aktuell – ebenfalls ohne Ereignis.
    @Test func brokenKnownPlistIsCarriedForwardUntilReadableAgain() async throws {
        try await ScratchDirectory.with(prefix: "launchd-broken") { directory in
            let plist = directory.appending(path: "agent.plist")
            try Self.write(Self.validPlist, to: plist)
            let first = try await Self.scan(directory, previous: nil, at: TestData.date)
            #expect(first.snapshot.autostartItems.map(\.isCurrent) == [true])

            try Data("kein plist".utf8).write(to: plist)
            let broken = try await Self.scan(directory, previous: first.snapshot, at: TestData.date + TestData.day)
            #expect(broken.events.isEmpty)
            #expect(broken.snapshot.sourceErrors.isEmpty)
            #expect(broken.snapshot.sourceLimitations.map(\.source) == [.launchd])
            let carried = try #require(broken.snapshot.autostartItems.first)
            #expect(broken.snapshot.autostartItems.count == 1)
            #expect(carried.id == first.snapshot.autostartItems[0].id)
            #expect(carried.lastVerifiedAt == TestData.date)
            #expect(carried.statusBadges.contains(.outdated))
            // Der Wechsel zu „alter Stand“ wird gespeichert, aber nicht gemeldet.
            #expect(!broken.snapshot.isEquivalent(to: first.snapshot))

            // Bleibt sie kaputt, bleibt der Zeitpunkt des letzten Lesens.
            let stillBroken = try await Self.scan(directory, previous: broken.snapshot, at: TestData.date + 2 * TestData.day)
            #expect(stillBroken.events.isEmpty)
            #expect(stillBroken.snapshot.autostartItems.map(\.lastVerifiedAt) == [TestData.date])
            #expect(stillBroken.snapshot.isEquivalent(to: broken.snapshot))

            try Self.write(Self.validPlist, to: plist)
            let restored = try await Self.scan(directory, previous: stillBroken.snapshot, at: TestData.date + 3 * TestData.day)
            #expect(restored.events.isEmpty)
            #expect(restored.snapshot.sourceLimitations.isEmpty)
            #expect(restored.snapshot.autostartItems.map(\.isCurrent) == [true])
        }
    }

    /// Eine tatsächlich gelöschte Plist ist weiterhin ein `removed`-Ereignis – auch wenn daneben eine kaputte liegt,
    /// und gültige andere Plists werden weiter gelesen.
    @Test func deletedPlistIsStillReportedAsRemoved() async throws {
        try await ScratchDirectory.with(prefix: "launchd-removed") { directory in
            let gone = directory.appending(path: "gone.plist")
            try Self.write(Self.validPlist, to: gone)
            try Self.write(["Label": "com.example.other", "Program": "/bin/ls"], to: directory.appending(path: "other.plist"))
            let first = try await Self.scan(directory, previous: nil, at: TestData.date)

            try FileManager.default.removeItem(at: gone)
            try Data("kaputt".utf8).write(to: directory.appending(path: "broken.plist"))
            let second = try await Self.scan(directory, previous: first.snapshot, at: TestData.date + TestData.day)

            #expect(second.events.map(\.kind) == [.removed])
            #expect(second.events.first?.subject.recordID == first.snapshot.autostartItems.first { $0.label == Self.label }?.id)
            #expect(second.snapshot.autostartItems.map(\.label) == ["com.example.other"])
            #expect(second.snapshot.autostartItems.allSatisfy { $0.isCurrent })
            #expect(second.snapshot.sourceLimitations.count == 1)
        }
    }

    /// Ein unlesbares Verzeichnis (keine Rechte) ist eine Lücke: seine Einträge bleiben mit altem Stand, bis es wieder
    /// lesbar ist.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte"))
    func unreadableDirectoryCarriesItsItemsForward() async throws {
        try await ScratchDirectory.with(prefix: "launchd-locked") { scratch in
            let directory = scratch.appending(path: "LaunchAgents")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.write(Self.validPlist, to: directory.appending(path: "agent.plist"))
            let first = try await Self.scan(directory, previous: nil, at: TestData.date)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            let locked: (snapshot: Snapshot, events: [ChangeEvent])
            do {
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
                locked = try await Self.scan(directory, previous: first.snapshot, at: TestData.date + TestData.day)
            }
            #expect(locked.events.isEmpty)
            #expect(locked.snapshot.sourceLimitations.map(\.message) == [
                "Verzeichnis \(directory.path) nicht lesbar (nicht lesbar) – bekannte Einträge bleiben mit altem Stand erhalten",
            ])
            #expect(locked.snapshot.autostartItems.map(\.lastVerifiedAt) == [TestData.date])

            let readable = try await Self.scan(directory, previous: locked.snapshot, at: TestData.date + 2 * TestData.day)
            #expect(readable.events.isEmpty)
            #expect(readable.snapshot.sourceLimitations.isEmpty)
            #expect(readable.snapshot.autostartItems.map(\.isCurrent) == [true])
        }
    }

    /// Fehlt das Suchrecht auf einem übergeordneten Verzeichnis (wie `~/Library`), ist das Agents-Verzeichnis nicht
    /// „fehlend“ – seine Einträge bleiben mit altem Stand, statt als entfernt zu gelten.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte"))
    func directoryBehindUnsearchableParentIsAGap() async throws {
        try await ScratchDirectory.with(prefix: "launchd-parent") { scratch in
            let parent = scratch.appending(path: "Library")
            let directory = parent.appending(path: "LaunchAgents")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.write(Self.validPlist, to: directory.appending(path: "agent.plist"))
            let first = try await Self.scan(directory, previous: nil, at: TestData.date)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
            let locked: (snapshot: Snapshot, events: [ChangeEvent])
            do {
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
                locked = try await Self.scan(directory, previous: first.snapshot, at: TestData.date + TestData.day)
            }
            #expect(locked.events.isEmpty)
            #expect(locked.snapshot.sourceLimitations.count == 1)
            #expect(locked.snapshot.autostartItems.map(\.lastVerifiedAt) == [TestData.date])

            let readable = try await Self.scan(directory, previous: locked.snapshot, at: TestData.date + 2 * TestData.day)
            #expect(readable.events.isEmpty)
            #expect(readable.snapshot.autostartItems.map(\.isCurrent) == [true])
        }
    }

    /// Eine Plist ohne Leserecht ist eine Lücke, kein Entfernen.
    @Test(.disabled(if: geteuid() == 0, "root umgeht Dateirechte"))
    func unreadablePlistIsAGap() async throws {
        try await ScratchDirectory.with(prefix: "launchd-mode") { directory in
            let plist = directory.appending(path: "agent.plist")
            try Self.write(Self.validPlist, to: plist)
            let first = try await Self.scan(directory, previous: nil, at: TestData.date)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: plist.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plist.path) }
            let second = try await Self.scan(directory, previous: first.snapshot, at: TestData.date + TestData.day)
            #expect(second.events.isEmpty)
            #expect(second.snapshot.autostartItems.map(\.lastVerifiedAt) == [TestData.date])
        }
    }

    // MARK: - Nur reguläre Dateien begrenzter Größe

    /// Eine FIFO mit Plist-Endung hält den Scan nicht an und ist eine Lücke; die übrigen Plists werden gelesen.
    @Test func fifoPlistDoesNotBlockAndIsAGap() async throws {
        try await ScratchDirectory.with(prefix: "launchd-fifo") { directory in
            try Self.write(Self.validPlist, to: directory.appending(path: "agent.plist"))
            let fifo = try FIFOFixture.make(in: directory, named: "fifo.plist")
            let source = Self.source(directory)
            let collected = await FIFOFixture.completes(unblocking: fifo) { try? await source.collect() }
            let contribution = try #require(collected ?? nil)
            #expect(contribution.autostartItems.map(\.label) == [Self.label])
            #expect(contribution.incompletePlistPaths == [fifo.path])
            #expect(contribution.limitations.first?.contains(RegularFileReader.notRegularText) == true)
        }
    }

    /// Eine übergroße Datei wird nicht gelesen, sondern als Lücke gemeldet.
    @Test func oversizedPlistIsAGap() async throws {
        try await ScratchDirectory.with(prefix: "launchd-size") { directory in
            let big = directory.appending(path: "big.plist")
            try Data(count: LaunchdSource.maximumPlistSize + 1).write(to: big)
            let contribution = try await Self.source(directory).collect()
            #expect(contribution.autostartItems.isEmpty)
            #expect(contribution.incompletePlistPaths == [big.path])
            #expect(contribution.limitations.first?.contains("größer als 1 MB") == true)
        }
    }

    /// Ein Verzeichnis statt einer Datei mit Plist-Endung ist keine reguläre Datei.
    @Test func directoryNamedLikeAPlistIsAGap() async throws {
        try await ScratchDirectory.with(prefix: "launchd-dir") { directory in
            let odd = directory.appending(path: "odd.plist")
            try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
            #expect(LaunchdSource.readPlist(at: odd.path).unreadableReason == RegularFileReader.notRegularText)
        }
    }

    /// Eine während des Auflistens verschwundene Plist ist keine Lücke.
    @Test func vanishedPlistIsMissing() {
        #expect(LaunchdSource.readPlist(at: "/nonexistent/agent.plist").isMissing)
    }

    // MARK: - Ladezustand bei unvollständiger Domain

    /// Fehlt in einer Domain eine Plist (nicht auswertbar), ist ihr Label unbekannt: Ein geladenes Label könnte aus ihr
    /// stammen. Die Quelle fragt den Dienst dann einzeln ab, statt ihn der lesbaren Plist zuzuschreiben.
    @Test func loadedLabelsAreProbedWhenTheDomainHasGaps() async throws {
        try await ScratchDirectory.with(prefix: "launchd-probe") { directory in
            try Self.write(Self.validPlist, to: directory.appending(path: "agent.plist"))
            try Data("kaputt".utf8).write(to: directory.appending(path: "broken.plist"))
            let runner = Self.runner()
            runner.stub("/bin/launchctl print gui/501", CommandResult(
                exitCode: 0, stdout: "gui/501 = {\n\tservices = {\n\t\t     750      - \t\(Self.label)\n\t}\n}\n"
            ))
            runner.stub("/bin/launchctl print gui/501/\(Self.label)", CommandResult(
                exitCode: 0, stdout: "gui/501/x = {\n\tpath = \(directory.path)/broken.plist\n}\n"
            ))
            let items = try await Self.source(directory, runner: runner).collect().autostartItems
            #expect(runner.calls.contains("/bin/launchctl print gui/501/\(Self.label)"))
            #expect(items.map(\.isLoaded) == [false])
        }
    }

    // MARK: - Fortschreibung als reine Funktion

    @Test func carryingForwardIsIdempotentAndLimitedToGaps() {
        var inGap = TestData.item("a")
        inGap.plistPath = "/gap/a.plist"
        var inGapDirectory = TestData.item("b")
        inGapDirectory.plistPath = "/locked/b.plist"
        var elsewhere = TestData.item("c")
        elsewhere.plistPath = "/read/c.plist"
        let previous = TestData.snapshot(items: [inGap, inGapDirectory, elsewhere])
        let current = TestData.snapshot(items: [], at: TestData.date + TestData.day)

        let once = current.carryingForwardAutostartItems(inIncompletePlistPaths: ["/gap/a.plist", "/locked"], from: previous)
        let twice = once.carryingForwardAutostartItems(inIncompletePlistPaths: ["/gap/a.plist", "/locked"], from: previous)

        #expect(once.autostartItems.map(\.label) == ["a", "b"])
        #expect(once.autostartItems.map(\.lastVerifiedAt) == [TestData.date, TestData.date])
        #expect(twice == once)
    }

    @Test func outdatedItemsAreReadOnlyAndNamedInTheDetail() {
        let item = TestData.item().carriedForward(scannedAt: TestData.date)
        #expect(ActionPolicy().availability(for: item) == .readOnly(.outdatedState))
        #expect(item.verificationNote(now: TestData.date + 3 * TestData.day, calendar: TestData.utcCalendar)
            == "Plist zuletzt nicht auswertbar – Stand von vor 3 Tagen")
        #expect(TestData.item().verificationNote(now: TestData.date) == nil)
    }

    /// Ältere Snapshots kennen `lastVerifiedAt` nicht: Ihre Einträge gelten als aktuell.
    @Test func decodesItemsWithoutVerificationDateAsCurrent() throws {
        var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(TestData.item())) as? [String: Any])
        encoded["lastVerifiedAt"] = nil
        let decoded = try JSONDecoder().decode(AutostartItem.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.isCurrent)
        #expect(decoded == TestData.item())
    }
}

extension LaunchdSource.PlistRead {
    fileprivate var isMissing: Bool {
        if case .missing = self { true } else { false }
    }

    fileprivate var unreadableReason: String? {
        if case .unreadable(let reason) = self { reason } else { nil }
    }
}
