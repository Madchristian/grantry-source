/// Obergrenzen für Wanduhr-Prüfungen der Art „kehrt nach der kurzen Frist zurück, nicht erst nach der langen“.
///
/// Sie messen keine Reaktionszeit: Die Suite startet rund 2400 Tests gleichzeitig; auf einem CI-Runner mit drei Kernen
/// wartet die Fortsetzung eines Tasks im kooperativen Pool dabei mehrere Sekunden. Welche Frist griff, belegt die
/// Fehlermeldung („Zeitüberschreitung nach 0,2 s“); die Wanduhr schließt nur aus, dass erst die lange Frist ablief.
enum LatencyBound {
    /// Deutlich unter den Fristen von 45 s und mehr, die in diesen Tests nicht greifen dürfen.
    static let wellBeforeLongTimeouts: Duration = .seconds(30)
}
