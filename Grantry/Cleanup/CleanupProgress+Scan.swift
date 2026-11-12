import GrantryCharts
import ManagerKit

extension CleanupProgress {
    /// Laufender Scan eines Aufräumen-Segments als Spur neben dem Umschalter (Spec 2026-11-10 § 11.4): Anteil der
    /// Schritte, unbestimmt mit leerer Bahn und „Dauer noch unbekannt“; Ton `info`. Kein eigener Takt: Text und Anteil
    /// wechseln mit den Schritten des Scans. `title` etwa „Suche läuft“ in App-Reste.
    static func scanning(_ progress: ScanProgress, title: String = String(localized: "Scan läuft")) -> CleanupProgress {
        CleanupProgress(
            title: title,
            detail: progress.isIndeterminate
                ? String(localized: "Dauer noch unbekannt") : ScanProgressView.valueText(progress),
            fraction: progress.isIndeterminate ? nil : progress.fraction,
            tone: .info
        )
    }
}
