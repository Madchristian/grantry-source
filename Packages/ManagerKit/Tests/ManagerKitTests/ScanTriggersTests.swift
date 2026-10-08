import Testing
import Foundation
import TestSupport
@testable import ManagerKit

/// Watcher, dessen Signale der Test auslöst; meldet jedes Abonnement über `subscriptions`.
private final class FakeWatcher: FileSystemWatching {
    /// Beobachtete Verzeichnisse und Dateien eines Abonnements.
    struct Subscription: Equatable, Sendable {
        let paths: [String]
        let files: [String]
        let shallowPaths: [String]
    }

    private let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let subscriptions: AsyncStream<Subscription>
    private let subscribed: AsyncStream<Subscription>.Continuation

    init() {
        (stream, continuation) = AsyncStream<String>.makeStream()
        (subscriptions, subscribed) = AsyncStream<Subscription>.makeStream()
    }

    /// Wartet auf das erste Abonnement und liefert dessen Pfade.
    func firstSubscription() async -> Subscription? {
        await subscriptions.first { _ in true }
    }

    func changes(in paths: [String], files: [String], shallowPaths: [String]) -> AsyncStream<String> {
        subscribed.yield(Subscription(paths: paths, files: files, shallowPaths: shallowPaths))
        return stream
    }

    func signal(_ path: String) { continuation.yield(path) }
}

/// Zeitpunkte relativ zum Start der `TestClock`, in Millisekunden (exakt, ohne Gleitkomma).
private func at(ms: Int) -> TestClock.Instant { .at(.milliseconds(ms)) }

private let debounceMS = 2_000
private let intervalMS = 900_000
private let maxDelayMS = 10_000

@Suite(.timeLimit(.minutes(1)))
struct ScanTriggersTests {
    private let watcher = FakeWatcher()
    let clock = TestClock()

    private func makeTriggers() -> ScanTriggers {
        ScanTriggers(watcher: watcher, paths: ["/watched"], files: ["/watched.plist"], clock: clock)
    }

    /// Stellt die Uhr auf den absoluten Zeitpunkt `ms`.
    private func advance(to ms: Int) {
        clock.advance(by: clock.now.duration(to: at(ms: ms)))
    }

    /// Löst ein Dateisignal aus und wartet, bis dessen Entprell-Schlaf läuft. Die Frist `ms + debounce` darf mit
    /// keinem anderen wartenden Schläfer übereinstimmen.
    private func signal(atMS ms: Int, path: String = "/watched/a.plist") async {
        advance(to: ms)
        watcher.signal(path)
        await clock.waitForSleeper(until: at(ms: ms + debounceMS))
    }

    @Test func emitsLaunchFirstAndWatchesGivenPaths() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        #expect(await watcher.firstSubscription() == .init(paths: ["/watched"], files: ["/watched.plist"], shallowPaths: []))
    }

    @Test func shallowPathsReachTheWatcher() async {
        let watcher = FakeWatcher()
        let triggers = ScanTriggers(watcher: watcher, paths: ["/a"], files: ["/b"], shallowPaths: ["/Applications"], clock: TestClock())
        _ = await triggers.reasons()
        #expect(await watcher.firstSubscription() == .init(paths: ["/a"], files: ["/b"], shallowPaths: ["/Applications"]))
    }

    @Test func manualRequestIsEmittedImmediately() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)
        #expect(clock.now == .start)
    }

    /// Angeforderter Teilscan (etwa nach „Der Dienst läuft nicht mehr.“): sofort, ohne die Intervallfrist zurückzusetzen.
    @Test func requestedSourceRefreshIsEmittedImmediatelyWithoutResettingInterval() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        await clock.waitForSleeper(until: at(ms: intervalMS))
        advance(to: 1_000)
        await triggers.requestScan(only: [.networkListeners])
        #expect(await reasons.next() == .sourceRefresh([.networkListeners]))
        advance(to: intervalMS)
        #expect(await reasons.next() == .interval)
    }

    @Test func burstOfFileSignalsIsDebouncedIntoOneScan() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        for ms in stride(from: 0, through: 800, by: 200) {
            await signal(atMS: ms, path: "/watched/\(ms).plist")
        }

        // 1,9 s nach dem letzten Signal: noch kein Scan – das manuelle Signal kommt zuerst.
        advance(to: 2_700)
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)

        advance(to: 2_800)
        // Ein Scan je Serie; er nennt das erste Signal der Serie.
        #expect(await reasons.next() == .fileChange(path: "/watched/0.plist"))

        // Genau ein Dateiscan: Als Nächstes folgt wieder das manuelle Signal.
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)
    }

    @Test func continuousSignalsAreFlushedAfterMaxDelay() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        await signal(atMS: 0)
        await clock.waitForSleeper(until: at(ms: maxDelayMS))
        // Versetzt um 500 ms: Keine Entprellfrist fällt auf die Höchstfrist (sonst träfe `waitForSleeper` den
        // falschen Schläfer, bevor das Signal verarbeitet ist).
        for ms in stride(from: 500, through: 9_500, by: 1_000) {
            await signal(atMS: ms)
        }

        advance(to: maxDelayMS)
        #expect(await reasons.next() == .fileChange(path: "/watched/a.plist"))

        // Das nächste Signal beginnt eine neue Serie mit eigener Höchstwartezeit.
        await signal(atMS: 10_500, path: "/watched/next.plist")
        await clock.waitForSleeper(until: at(ms: 10_500 + maxDelayMS))
        advance(to: 11_000)
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)
        advance(to: 10_500 + debounceMS)
        #expect(await reasons.next() == .fileChange(path: "/watched/next.plist"))
    }

    @Test func intervalFiresAfterQuietPeriod() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        await clock.waitForSleeper(until: at(ms: intervalMS))
        advance(to: intervalMS)
        #expect(await reasons.next() == .interval)
        // Das Intervall läuft danach erneut.
        await clock.waitForSleeper(until: at(ms: 2 * intervalMS))
        advance(to: 2 * intervalMS)
        #expect(await reasons.next() == .interval)
    }

    @Test func fileScanResetsInterval() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        await clock.waitForSleeper(until: at(ms: intervalMS))

        await signal(atMS: 500_000)
        advance(to: 500_000 + debounceMS)
        #expect(await reasons.next() == .fileChange(path: "/watched/a.plist"))
        let resetDeadline = 500_000 + debounceMS + intervalMS
        await clock.waitForSleeper(until: at(ms: resetDeadline))

        // Die ursprüngliche Intervallfrist verstreicht ohne Scan.
        advance(to: intervalMS)
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)
    }

    @Test func manualScanResetsInterval() async {
        let triggers = makeTriggers()
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        await clock.waitForSleeper(until: at(ms: intervalMS))
        advance(to: 100_000)
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)
        await clock.waitForSleeper(until: at(ms: 100_000 + intervalMS))

        advance(to: intervalMS)
        await triggers.requestScan()
        #expect(await reasons.next() == .manual)
        await clock.waitForSleeper(until: at(ms: 2 * intervalMS))
        advance(to: 2 * intervalMS)
        #expect(await reasons.next() == .interval)
    }

    /// Eigener Quellentakt: Teilscans alle 60 s, ohne die Frist des Sicherheitsscans zurückzusetzen.
    @Test func sourceIntervalsEmitRefreshesWithoutResettingInterval() async {
        let triggers = ScanTriggers(watcher: watcher, paths: ["/watched"], interval: .milliseconds(intervalMS),
                                    sourceIntervals: [.networkListeners: .seconds(60)], clock: clock)
        var reasons = await triggers.reasons().makeAsyncIterator()
        #expect(await reasons.next() == .launch)
        for ms in stride(from: 60_000, to: intervalMS, by: 60_000) {
            await clock.waitForSleeper(until: at(ms: ms))
            advance(to: ms)
            #expect(await reasons.next() == .sourceRefresh([.networkListeners]))
            // Die Intervallfrist steht weiter beim Start + 900 s.
            await clock.waitForSleeper(until: at(ms: intervalMS))
        }
        // Bei 900 s fallen Teilscan und Sicherheitsscan zusammen; die Reihenfolge ist offen.
        await clock.waitForSleeper(until: at(ms: intervalMS))
        advance(to: intervalMS)
        let last = [await reasons.next(), await reasons.next()]
        #expect(last.contains(.interval))
        #expect(last.contains(.sourceRefresh([.networkListeners])))
    }

    /// Protokolltext je Anlass; bei Dateiänderungen mit dem auslösenden Pfad.
    @Test func reasonsDescribeThemselves() {
        #expect(ScanReason.fileChange(path: "/watched/a.plist").description == "Dateiänderung (/watched/a.plist)")
        #expect(ScanReason.interval.description == "Intervall")
        #expect(ScanReason.manual.description == "manuell")
        #expect(ScanReason.launch.description == "Start")
        #expect(ScanReason.sourceRefresh([.networkListeners, .apps]).description == "Quellen (apps, network.listeners)")
    }

    /// Das Protokoll ist öffentlich lesbar: Der Benutzerordner (und damit der Kontoname) erscheint nur als `~`.
    @Test(arguments: [
        ("/Users/anna/Library/LaunchAgents/a.plist", "Dateiänderung (~/Library/LaunchAgents/a.plist)"),
        ("/Users/anna", "Dateiänderung (~)"),
        ("/Users/annabel/Library/a.plist", "Dateiänderung (/Users/annabel/Library/a.plist)"),
        ("/Library/LaunchDaemons/b.plist", "Dateiänderung (/Library/LaunchDaemons/b.plist)"),
    ])
    func fileChangeAbbreviatesTheHomeDirectory(path: String, description: String) {
        #expect(ScanReason.fileChange(path: path).description(home: "/Users/anna") == description)
        #expect(ScanReason.fileChange(path: path).description(home: "/Users/anna/") == description)
    }

    @Test func descriptionUsesTheCurrentHomeDirectory() {
        let path = NSHomeDirectory() + "/Library/LaunchAgents/a.plist"
        #expect(ScanReason.fileChange(path: path).description == "Dateiänderung (~/Library/LaunchAgents/a.plist)")
    }

    @Test func secondConsumerGetsFinishedStream() async {
        let triggers = makeTriggers()
        _ = await triggers.reasons()
        var second = await triggers.reasons().makeAsyncIterator()
        #expect(await second.next() == nil)
    }
}
