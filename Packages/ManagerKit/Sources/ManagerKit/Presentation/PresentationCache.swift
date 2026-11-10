import Foundation

/// Merkt sich eine aufwendig gebaute Darstellung, bis sich ihr Schlüssel ändert (Bewertung 2026.11.9, Mangel 2, #478).
/// Die Tabellen des Task-Managers bauen ihre Zeilen damit einmal je Messtakt und Bedienzustand – nicht bei jeder
/// Auswertung von `body`, etwa nach einer `ps`- oder nettop-Messung zwischen zwei Takten oder einem Klick auf eine Zeile.
/// Was `make` liest, beobachtet SwiftUI nur, wenn neu gebaut wird; neue Zweitmessungen erscheinen so mit dem nächsten
/// Takt, und die Ansicht zeichnet je Takt einmal. Gehört als `@State` in die Ansicht.
@MainActor
public final class PresentationCache<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    public init() {}

    public func value(for key: Key, _ make: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = make()
        entry = (key, value)
        return value
    }
}

/// Schlüssel einer Tabelle des Task-Managers: Messtakt (`TaskManagerModel.frameDate`) und Bedienzustand.
public struct TableKey<Options: Equatable>: Equatable {
    public let measuredAt: Date
    public let options: Options

    public init(measuredAt: Date, options: Options) {
        self.measuredAt = measuredAt
        self.options = options
    }
}
