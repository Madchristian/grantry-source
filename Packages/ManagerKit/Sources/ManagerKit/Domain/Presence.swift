/// Ob ein Programm oder App-Bundle auf der Platte vorhanden ist.
///
/// `unknown` ist bewusst kein `missing`: Ohne Leserecht auf ein Elternverzeichnis (z. B. root-only unter `/Library`)
/// oder bei einer Bundle-ID, die Launch Services nicht kennt (Systemerweiterungen, eingebettete Helfer,
/// XPC-Dienste), lässt sich das Fehlen nicht beweisen.
///
/// `probablyMissing`: Weder Launch Services noch der (aktive) Spotlight-Index kennen die Bundle-ID – typisch für
/// eine gelöschte App, aber kein Beweis (z. B. in einem von Spotlight ausgeschlossenen Ordner).
public enum Presence: String, Hashable, Sendable, Codable {
    case present, missing, probablyMissing, unknown

    /// Übersetzt das Bool-Feld älterer, gespeicherter Snapshots (`exists` bzw. `programExists`).
    init(legacyExists exists: Bool) {
        self = exists ? .present : .missing
    }
}
