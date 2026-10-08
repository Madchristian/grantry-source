import Foundation

/// Ergebnis einer Spotlight-Suche nach einer Bundle-ID.
public enum SpotlightLookup: Hashable, Sendable {
    /// Mindestens ein Bundle mit dieser ID ist indiziert.
    case found
    /// Der Index ist aktiv und kennt kein Bundle mit dieser ID.
    case notFound
    /// Keine belastbare Antwort: ungültige ID, Index deaktiviert, Fehler oder Zeitüberschreitung.
    case unavailable
}

/// Sucht Bundles über den Spotlight-Index – der Fallback, wenn Launch Services eine Bundle-ID nicht kennt.
public protocol BundleSpotlightLocating: Sendable {
    func lookup(bundleID: String) async -> SpotlightLookup
}

/// Implementierung über `mdfind` (typisch wenige zehn Millisekunden pro Anfrage).
///
/// Ein leeres Ergebnis zählt nur, wenn der Index des Datenvolumes aktiv ist (`mdutil -s`, höchstens einmal je
/// `indexingProbeTTL` geprüft – auch eine gescheiterte Prüfung wird so wiederholt); sonst bewiese es nichts. Ordner, die in den Spotlight-Einstellungen ausgeschlossen sind, erkennt die
/// Prüfung nicht – eine dort liegende App gälte als vermutlich fehlend.
public actor SpotlightBundleLocator: BundleSpotlightLocating {
    private static let mdfind = "/usr/bin/mdfind"
    private static let mdutil = "/usr/bin/mdutil"
    /// Enthält `/Applications` und die Benutzerordner.
    private static let dataVolume = "/System/Volumes/Data"

    /// Gültigkeit (Sekunden) des Ergebnisses der Indexprüfung.
    static let indexingProbeTTL: TimeInterval = 60

    private let runner: any CommandRunning
    private let timeout: Duration
    private let now: @Sendable () -> Date
    private var indexingProbe = ExpiringTaskCache<String, Bool> { _ in indexingProbeTTL }

    public init(
        runner: any CommandRunning = ProcessCommandRunner(), timeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.timeout = timeout
        self.now = now
    }

    public func lookup(bundleID: String) async -> SpotlightLookup {
        // Nur Zeichen, die in Bundle-IDs erlaubt sind – die ID landet in einer mdfind-Abfrage.
        guard Self.isValidBundleID(bundleID), await isIndexingEnabled() else { return .unavailable }
        // `'…'c`: ohne Groß-/Kleinschreibung wie Launch Services (Review N1; `==[c]` ist NSPredicate, nicht mdfind).
        let query = "kMDItemCFBundleIdentifier == '\(bundleID)'c"
        guard let result = try? await runner.run(Self.mdfind, [query], timeout: timeout), result.succeeded else {
            return .unavailable
        }
        return result.stdout.contains { !$0.isWhitespace } ? .found : .notFound
    }

    /// `[A-Za-z0-9._-]+`
    static func isValidBundleID(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && bundleID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    private func isIndexingEnabled() async -> Bool {
        let runner = runner, timeout = timeout
        let task = indexingProbe.task(for: Self.dataVolume, now: now()) {
            let result = try? await runner.run(Self.mdutil, ["-s", Self.dataVolume], timeout: timeout)
            return result?.succeeded == true && result?.stdout.contains("Indexing enabled.") == true
        }
        let enabled = await task.value
        indexingProbe.finish(Self.dataVolume, task: task, value: enabled, now: now())
        return enabled
    }
}
