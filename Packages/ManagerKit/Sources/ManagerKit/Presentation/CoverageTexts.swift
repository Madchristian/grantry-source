extension Snapshot {
    /// `true`, wenn eine Quelle ausgefallen ist oder nur eingeschränkt geliefert hat (etwa nicht auswertbare Plists,
    /// #139). Fehlende Änderungen sind dann keine Entwarnung.
    public var hasIncompleteCoverage: Bool { !sourceErrors.isEmpty || !sourceLimitations.isEmpty }
}

/// Texte für leere Änderungslisten (Übersicht, Menüleiste, Verlauf): Nur bei vollständig gelesenen Quellen heißt
/// „keine Änderungen“ auch „nichts passiert“.
public enum CoverageTexts {
    /// „Keine Änderungen seit dem ersten Scan.“ – bei unvollständiger Abdeckung (`Snapshot.hasIncompleteCoverage`)
    /// stattdessen der Hinweis, dass nicht alles lesbar war.
    public static func noChanges(hasIncompleteCoverage: Bool) -> String {
        hasIncompleteCoverage
            ? "Keine Änderungen erkannt – nicht alle Quellen sind vollständig lesbar (siehe Hinweise)."
            : "Keine Änderungen seit dem ersten Scan."
    }
}
