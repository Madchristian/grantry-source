import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkListenerBaselineTests {
    private let differ = SnapshotDiffer()
    private let later = TestData.date.addingTimeInterval(15 * 60)
    private let ownUID: UInt32 = 501
    private let limitation = SourceLimitation(
        source: .networkListeners, message: "\(NetworkListenerSource.limitationPrefix) – Helper nicht erreichbar: aus"
    )

    private var own: NetworkListener { TestData.listener() }
    private var newOwn: NetworkListener { TestData.listener("/opt/homebrew/bin/python3", port: 8000) }
    private var root: NetworkListener { TestData.listener("/usr/sbin/sshd", uid: 0, port: 22) }

    /// Snapshot, wie ihn der `ScanCoordinator` liefert: `limited` mit Einschränkung und ohne vollständige Baseline –
    /// es sei denn, eine frühere Lieferung war schon vollständig (`hadCompleteBaseline`).
    private func snapshot(
        _ listeners: [NetworkListener], limited: Bool, hadCompleteBaseline: Bool = false, at date: Date = TestData.date
    ) -> Snapshot {
        var snapshot = TestData.networkSnapshot(listeners, at: date)
        snapshot.sourceLimitations = limited ? [limitation] : []
        snapshot.hasCompleteListenerBaseline = !limited || hadCompleteBaseline
        return snapshot
    }

    private func events(from previous: Snapshot, to current: Snapshot) -> [ChangeEvent] {
        NetworkListenerBaseline.filtering(differ.diff(from: previous, to: current), previous: previous,
                                          current: current, currentUID: ownUID)
    }

    /// Erste vollständige Lieferung nach eingeschränkter Erfassung: Fremde Lauscher sind Baseline, eigene nicht.
    @Test func firstCompleteDeliveryAfterLimitedScanIsBaselineForForeignListeners() {
        let previous = snapshot([own], limited: true)
        let current = snapshot([own, newOwn, root], limited: false, at: later)

        let events = events(from: previous, to: current)

        #expect(events.map(\.kind) == [.added])
        #expect(events.first?.subject == .networkListener(newOwn))
    }

    /// Eingeschränkt → Quelle scheitert → vollständig: Der gescheiterte Scan schreibt nur die Einträge fort, nicht die
    /// Einschränkung. Er gilt trotzdem nicht als vollständiger Ausgangszustand – fremde Lauscher sind Baseline.
    @Test func firstCompleteDeliveryAfterFailedScanIsBaselineForForeignListeners() {
        let limited = snapshot([own], limited: true)
        var failed = snapshot([], limited: true, at: later)
        failed.sourceLimitations = []
        failed.sourceErrors = [SourceError(source: .networkListeners, message: "Zeitüberschreitung")]
        let previous = failed.carryingForwardRecords(ofFailedSourcesFrom: limited)
        let current = snapshot([own, newOwn, root], limited: false, at: later.addingTimeInterval(15 * 60))

        let events = events(from: previous, to: current)

        #expect(previous.sourceLimitations.isEmpty)
        #expect(!previous.hasCompleteListenerBaseline)
        #expect(events.map(\.kind) == [.added])
        #expect(events.first?.subject == .networkListener(newOwn))
    }

    @Test func newForeignListenerBetweenCompleteScansIsReported() {
        let previous = snapshot([own], limited: false)
        let current = snapshot([own, root], limited: false, at: later)

        #expect(events(from: previous, to: current).map(\.subject) == [.networkListener(root)])
    }

    /// Vollständig → Helper fällt aus (fremde Lauscher fortgeschrieben) → vollständig: Ein in der Lücke entstandener
    /// fremder Dienst wird gemeldet. Die Baseline-Regel gilt nur für die allererste vollständige Lieferung.
    @Test func newForeignListenerAfterHelperOutageIsReported() {
        let outage = snapshot([own, root], limited: true, hadCompleteBaseline: true)
        let intruder = TestData.listener("/usr/local/sbin/intruder", uid: 0, port: 4444)
        let recovered = snapshot([own, root, intruder], limited: false, at: later)

        #expect(events(from: outage, to: recovered).map(\.subject) == [.networkListener(intruder)])
    }

    @Test func limitedScansStayUnchanged() {
        let previous = snapshot([own], limited: true)
        let current = snapshot([own, newOwn, root], limited: true, at: later)
        let raw = differ.diff(from: previous, to: current)

        #expect(raw.count == 2)
        #expect(NetworkListenerBaseline.filtering(raw, previous: previous, current: current, currentUID: ownUID) == raw)
    }

    /// Fällt die Quelle aus, liefert sie nicht vollständig – nichts wird verworfen.
    @Test func failedSourceIsNotACompleteDelivery() {
        let previous = snapshot([own], limited: true)
        var current = snapshot([own, root], limited: true, at: later)
        current.sourceLimitations = []
        current.sourceErrors = [SourceError(source: .networkListeners, message: "kaputt")]
        let raw = [ChangeEvent(kind: .added, before: nil, after: .networkListener(root), detectedAt: later)]

        #expect(NetworkListenerBaseline.filtering(raw, previous: previous, current: current, currentUID: ownUID) == raw)
    }

    /// Nur `.added` fremder Lauscher entfällt: Entfernte und geänderte bleiben, ebenso andere Eintragsarten.
    @Test func onlyAddedForeignListenersAreDropped() {
        let previous = snapshot([own, root], limited: true)
        var changedRoot = root
        changedRoot.signing = SigningInfo(kind: .unsigned)
        let grant = TestData.grant()
        let raw = [
            ChangeEvent(kind: .modified, before: .networkListener(root), after: .networkListener(changedRoot),
                        detectedAt: later),
            ChangeEvent(kind: .removed, before: .networkListener(own), after: nil, detectedAt: later),
            ChangeEvent(kind: .added, before: nil, after: .grant(grant), detectedAt: later),
        ]
        let current = snapshot([changedRoot], limited: false, at: later)

        #expect(NetworkListenerBaseline.filtering(raw, previous: previous, current: current, currentUID: ownUID) == raw)
    }

    @Test func withoutPreviousNothingChanges() {
        let current = snapshot([root], limited: false)
        let raw = [ChangeEvent(kind: .added, before: nil, after: .networkListener(root), detectedAt: TestData.date)]

        #expect(NetworkListenerBaseline.filtering(raw, previous: nil, current: current, currentUID: ownUID) == raw)
    }
}
