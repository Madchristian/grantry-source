/// Anzeige eines eingeschalteten Menüleisten-Elements: Werte, Darstellung und Kurzbezeichnung – alles, was sein Bild
/// bestimmt.
public struct MenuBarMeterEntry: Equatable, Sendable {
    public let kind: MenuBarMeterKind
    public let reading: MenuBarMeterReading
    public let style: MenuBarMeterStyle
    public let showsTags: Bool

    public init(kind: MenuBarMeterKind, reading: MenuBarMeterReading, style: MenuBarMeterStyle, showsTags: Bool) {
        self.kind = kind
        self.reading = reading
        self.style = style
        self.showsTags = showsTags
    }
}

/// Was die Statusobjekte nach einem Takt neu setzen bzw. entfernen.
public struct MenuBarMeterChanges: Equatable, Sendable {
    /// Elemente mit geänderter Anzeige, in der Reihenfolge der Einstellungen.
    public var updated: [MenuBarMeterEntry] = []
    /// Ausgeschaltete Elemente.
    public var removed: [MenuBarMeterKind] = []

    public init() {}
}

/// Zuletzt gesetzter Stand der Statusobjekte (#482): Jedes Setzen eines Statusobjekts kostet unter macOS 26 mehrere
/// Millisekunden (Schnappschüsse der Menüleiste, Neuzeichnen, Szenen-Abgleich); die Tafel meldet je Takt nur, was sich
/// sichtbar geändert hat – Thermik und Akku etwa bleiben meist gleich.
public struct MenuBarMeterBoard: Sendable {
    private var shown: [MenuBarMeterKind: MenuBarMeterEntry] = [:]

    public init() {}

    /// Übernimmt die Anzeigen der eingeschalteten Elemente (`MenuBarMetersModel.entries(in:)`).
    public mutating func update(_ entries: [MenuBarMeterEntry]) -> MenuBarMeterChanges {
        var changes = MenuBarMeterChanges()
        changes.updated = entries.filter { shown[$0.kind] != $0 }
        let kinds = Set(entries.map(\.kind))
        changes.removed = MenuBarMeterKind.allCases.filter { shown[$0] != nil && !kinds.contains($0) }
        shown = Dictionary(uniqueKeysWithValues: entries.map { ($0.kind, $0) })
        return changes
    }

    /// Der nächste Takt setzt alle Elemente neu, etwa nach geändertem Kontrast.
    public mutating func invalidate() {
        shown = [:]
    }
}

extension MenuBarMetersModel {
    /// Anzeigen der eingeschalteten Elemente zu `frame`, in der Reihenfolge der Einstellungen; ausgeschaltete Elemente
    /// berechnet sie nicht.
    public func entries(in frame: TaskManagerFrame) -> [MenuBarMeterEntry] {
        MenuBarMeterKind.allCases.filter(isShown).map { kind in
            MenuBarMeterEntry(kind: kind, reading: MenuBarMeterPresentation.reading(for: kind, in: frame),
                              style: style(for: kind), showsTags: showsTags)
        }
    }
}
