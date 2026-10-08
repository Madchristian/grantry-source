import Foundation
import Synchronization

/// Führt blockierende Aufrufe (Signaturprüfung über Security.framework) mit Zeitgrenze auf eigenen Threads aus.
///
/// `SecStaticCodeCreateWithPath`/`SecStaticCodeCheckValidity` lassen sich nicht abbrechen und können an einer FIFO
/// unbegrenzt hängen – auch nach der Vorprüfung (`FileType.isSafeToInspect`), wenn ein Prozess die Datei im Rennen
/// austauscht. Der Aufrufer wartet daher höchstens die Frist und erhält dann `nil`; der hängende Thread läuft weiter,
/// bis der Aufruf von selbst endet.
///
/// Damit hängende Threads sich nicht anhäufen, zählt der Guard Aufrufe, deren Frist abgelaufen ist und die noch
/// laufen. Hängen bereits `maximumHanging`, kehrt jeder weitere Aufruf sofort mit `nil` zurück, ohne zu laufen. Laufende
/// Aufrufe innerhalb der Frist zählen nicht – gleichzeitige Prüfungen bremsen sich so nicht gegenseitig aus. Threads
/// gibt es damit höchstens `maximumHanging` plus so viele, wie Aufrufer gleichzeitig warten.
///
/// **Synchroner Guard:** Auch das Warten auf die Frist blockiert. Async-Aufrufer müssen die ganze synchrone
/// Aufbereitung über `BlockingWorkQueue` (oder eine eigene Queue wie `ActivityProgramResolver`) auslagern, damit
/// weder dieses Warten noch weitere synchrone Systemabfragen den kooperativen Pool belegen.
final class BlockingCallGuard: Sendable {
    /// Für die Signaturprüfung (`SecuritySigningInspector`).
    static let signing = BlockingCallGuard(maximumHanging: 4)
    /// Für Launch-Services-Abfragen (`WorkspaceBundleLocator`): Ein hängender `lsd` belegt so keine Plätze der
    /// Signaturprüfung.
    static let launchServices = BlockingCallGuard(maximumHanging: 2)
    /// Für die Tiefenprüfung (`SecuritySignatureValidator`): läuft ohnehin seriell.
    static let deepValidation = BlockingCallGuard(maximumHanging: 2)
    /// Für Größenberechnungen (`FileSizeCalculator`): laufen seriell je Aufrufer (`AppDetailsLoader`) bzw. begrenzt
    /// parallel (`LeftoverScanner`) und brechen nach der Frist selbst ab.
    static let fileSize = BlockingCallGuard(maximumHanging: 2)
    /// Für Spotlight-Abfragen (`SpotlightLastUsedReader`).
    static let spotlight = BlockingCallGuard(maximumHanging: 2)
    /// Für App-Symbole (`AppIconLoader`).
    static let icons = BlockingCallGuard(maximumHanging: 2)

    let maximumHanging: Int
    private let hanging = Mutex(0)

    init(maximumHanging: Int) {
        self.maximumHanging = maximumHanging
    }

    /// Aufrufe nach Ablauf ihrer Frist, die noch laufen.
    var hangingCount: Int { hanging.withLock { $0 } }

    /// `true`, solange `maximumHanging` Aufrufe hängen – jeder weitere kehrt sofort ohne Ergebnis zurück.
    var isExhausted: Bool { hangingCount >= maximumHanging }

    /// Ergebnis von `body`, wenn er innerhalb von `timeout` endet; `nil` nach Ablauf der Frist oder sofort, wenn
    /// bereits `maximumHanging` Aufrufe hängen.
    func run<T: Sendable>(timeout: Duration, _ body: @escaping @Sendable () -> T) -> T? {
        guard !isExhausted else { return nil }
        let call = Call<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            if call.finish(with: body()) { hanging.withLock { $0 -= 1 } }
            done.signal()
        }
        thread.qualityOfService = .utility
        thread.start()
        if done.wait(timeout: .now() + Self.interval(timeout)) == .success { return call.result }
        return call.abandon { hanging.withLock { $0 += 1 } }
    }

    private static func interval(_ duration: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    /// Zustand eines Aufrufs zwischen Thread und wartendem Aufrufer. Beide Seiten entscheiden unter derselben Sperre,
    /// ob der Aufruf als hängend zählt – das Ende kurz nach Ablauf der Frist geht so nicht verloren.
    private final class Call<T: Sendable>: Sendable {
        private struct State {
            var result: T?
            var isFinished = false
            var isAbandoned = false
        }

        private let state = Mutex(State())

        var result: T? { state.withLock { $0.result } }

        /// Speichert das Ergebnis; `true`, wenn der Aufrufer bereits aufgegeben hat (der Aufruf zählte als hängend).
        func finish(with value: T) -> Bool {
            state.withLock { state in
                state.result = value
                state.isFinished = true
                return state.isAbandoned
            }
        }

        /// Gibt den Aufruf auf und zählt ihn per `markHanging` als hängend – außer er ist inzwischen fertig, dann
        /// zählt sein Ergebnis.
        func abandon(markHanging: () -> Void) -> T? {
            state.withLock { state in
                guard !state.isFinished else { return state.result }
                state.isAbandoned = true
                markHanging()
                return nil
            }
        }
    }
}
