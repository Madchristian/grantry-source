import Foundation

/// Kurztexte des Menüleisten-Menüs im Lagebild (LB-5.4, #555; Spec 2026-11-10 § 11 Entscheidung 7, § 11.5): Kenndaten
/// rechts in der Lagezeile und die Köpfe der Panels. Das Urteil selbst kommt unverändert aus `DashboardVerdict`.
public enum MenuBarMenuTexts {
    /// „Scan läuft“, „Scan 14:32“ (an einem anderen Tag mit Datum) oder „kein Scan“ – knapp für die 380 breite Lagezeile.
    public static func facts(isScanning: Bool, scannedAt: Date?, now: Date = .now) -> String {
        if isScanning { return String(localized: "Scan läuft") }
        guard let scannedAt else { return String(localized: "kein Scan") }
        let time = Calendar.current.isDate(scannedAt, inSameDayAs: now)
            ? scannedAt.formatted(date: .omitted, time: .shortened)
            : scannedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return String(localized: "Scan \(time)")
    }

    /// Kopf des Panels „Hinweise“: „3 offen“.
    public static func notices(_ count: Int) -> String {
        String(localized: "\(count) offen")
    }

    /// Kopf des Panels „Letzte Änderungen“: „5 neueste · 2 ungelesen“; ohne Änderungen leer.
    public static func changes(count: Int, unread: Int) -> String {
        guard count > 0 else { return "" }
        let newest = String(localized: "\(count) neueste")
        return unread > 0 ? newest + " · " + String(localized: "\(unread) ungelesen") : newest
    }

    /// Kopf des Panels „Beobachtung“ bei laufender Beobachtung: „„Beispiel-Tool“ seit 12 Min. · 2 neue Einträge“.
    public static func observation(name: String, startedAt: Date, now: Date, addedCount: Int?) -> String {
        let since = "„\(name)“ " + String(localized: "seit \(ObservationTexts.duration(from: startedAt, to: now))")
        guard let addedCount else { return since }
        return since + " · " + ObservationTexts.entries(addedCount)
    }
}
