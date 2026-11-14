import CoreGraphics

/// Maße des Einstellungsfensters: Breite wie bisher (Entwurf LB-5.1, Spec 2026-11-10 § 11 Entscheidung 3). Eigene Datei,
/// damit das Mess-Harness der Menüleiste den Tab „Menüleiste“ ohne das ganze Einstellungsfenster verlinken kann.
enum SettingsLayout {
    static let width: CGFloat = 560
}
