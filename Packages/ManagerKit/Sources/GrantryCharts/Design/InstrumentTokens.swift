import AppKit
import SwiftUI

// Tokens der Instrumententafel, Gestaltung „Lagebild“ (docs/design/instrumententafel.md §2). Die Ansichten des
// Task-Managers, des Popovers und der Verbindungen nehmen Abstände, Radien, Linien, Deckkraft, Maße und Schriften nur
// von hier; `scripts/tests/test_design_tokens.py` meldet Zahlen-Literale in diesen Ordnern.

/// Abstände (§2.8): Skala 2 · 4 · 6 · 8 · 10 · 12 · 14 · 16 · 24.
public enum InstrumentSpacing {
    /// Titel über Wert, Zeilenabstand in Tabellen, Rand der Rinne.
    public static let stack: CGFloat = 2
    /// Spaltenabstand in Tabellen, Symbol und kleiner Text.
    public static let inline: CGFloat = 4
    /// Elemente in Karten und Chips.
    public static let item: CGFloat = 6
    /// Abschnitte im Panel, Spuren untereinander, Zellen waagerecht.
    public static let group: CGFloat = 8
    /// Messfeld, Kopf zu Inhalt, Ring zu Titel.
    public static let cell: CGFloat = 10
    /// Zwischen Panels; Innenabstand aller Panels.
    public static let panel: CGFloat = 12
    /// Seitenrand, Lagezeile.
    public static let page: CGFloat = 14
    /// Tabellenkopf und Leisten waagerecht.
    public static let bar: CGFloat = 16
    /// Leerzustand.
    public static let empty: CGFloat = 24
}

/// Radien (§2.9), immer `style: .continuous`.
public enum InstrumentRadius {
    /// Graph-Rahmen, Mini-Graph, Kern-Zelle, Heatmap-Zelle.
    public static let graph: CGFloat = 4
    /// Gewählte Zeile, Tooltip.
    public static let control: CGFloat = 7
    /// Block im Chip-Grundriss, Messfeld.
    public static let block: CGFloat = 10
    /// Karte, Zählkachel.
    public static let card: CGFloat = 12
    /// Panel, Tabelle, Lagezeile.
    public static let panel: CGFloat = 14
}

/// Linien (§2.10).
public enum InstrumentStroke {
    public static let border: CGFloat = 1
    /// Rand der gewählten Karte.
    public static let focus: CGFloat = 2
    /// Fokusleiste der gewählten Zeile.
    public static let focusBar: CGFloat = 3
    public static let line: CGFloat = 1.75
    public static let lineIncreased: CGFloat = 2.5
    public static let sparkline: CGFloat = 1.5
    /// Grundlinie und Mittellinie.
    public static let base: CGFloat = 0.75
    /// Bahn des Peilrings.
    public static let ring: CGFloat = 3
    /// Bahn des Bogens.
    public static let arc: CGFloat = 8
    /// Ringe des Peilpunkts, Teilstriche.
    public static let echo: CGFloat = 1
}

/// Deckkraft (§2.11).
public enum InstrumentOpacity {
    public static let well = 0.06
    public static let subtle = 0.05
    public static let chip = 0.14
    public static let track = 0.18
    public static let block = 0.06
    public static let blockBorder = 0.45
    public static let blockBorderIncreased = 0.9
    /// Rahmen eines Graphen in der Farbe der Messgröße; neutral ohne Messgröße.
    public static let graphFrame = 0.6
    public static let graphFrameIncreased = 0.95
    public static let graphFrameNeutral = 0.16
    public static let graphFrameNeutralIncreased = 0.45
    /// Säulen: Grund plus Anteil je Füllung, hervorgehoben unter dem Zeiger.
    public static let barBase = 0.3
    public static let barRange = 0.5
    public static let barHovered = 0.85
    /// Grund des Tooltips am Fadenkreuz.
    public static let tooltip = 0.55
    /// Ringe des Erreichbarkeitsradars.
    public static let radarRing = 0.5
    /// Ruhiger Abschnitt eines Zustandsbands (Thermik normal); erhöht ≥ 3 : 1 auf dem Panel, hell wie dunkel.
    public static let quietBand = 0.18
    public static let quietBandIncreased = 0.45
    public static let area = 0.26
    public static let gone = 0.45
    public static let selectionDark = 0.24
    public static let selectionLight = 0.12
    public static let borderDark = 0.08
    public static let borderLight = 0.14
    public static let borderIncreased = 0.4
    public static let gridDot = 0.22
    public static let gridDotIncreased = 0.35
    public static let echoInner = 0.42
    public static let echoOuter = 0.16
    public static let secondaryLine = 0.35
    /// Sekundärer Text (`ShapeStyle.instrumentSecondary`).
    public static let secondaryText = 0.6
    /// Stufen des Belegungsbands vom festesten Teil (System) bis zum flüchtigsten (bereinigbar); frei ist die Bahn
    /// (`track`). Der Abstand je Stufe bleibt groß genug, um benachbarte Teile auch hell zu unterscheiden.
    public static let bandLevels = [1.0, 0.74, 0.52, 0.36, 0.26]
}

/// Feste Maße (§2.12).
public enum InstrumentSize {
    public static let peilRing: CGFloat = 22
    public static let peilRingCard: CGFloat = 26
    public static let arcGauge: CGFloat = 118
    public static let spurCard: CGFloat = 5
    public static let spurList: CGFloat = 6
    public static let spurTile: CGFloat = 8
    public static let spurHeader: CGFloat = 4
    public static let findingDot: CGFloat = 9
    public static let findingDotSmall: CGFloat = 7
    public static let statusDot: CGFloat = 6
    public static let shield: CGFloat = 44
    public static let shieldSmall: CGFloat = 20
    public static let rowIcon: CGFloat = 20
    public static let rowIconTall: CGFloat = 26
    public static let disclosure: CGFloat = 14
    public static let legendStroke = CGSize(width: 12, height: 3)
    public static let laneLabel: CGFloat = 120
    public static let laneHeight: CGFloat = 50
    /// Ereignisleiste des Wachbuchs: Spur der Befunde oben, Marken der Änderungen darunter.
    public static let eventBar: CGFloat = 36
    /// Kreis einer Marke in der Ereignisleiste.
    public static let eventMark: CGFloat = 16
    /// Schmales Zustandsband (Thermik im Wachbuch).
    public static let stateBand: CGFloat = 6
    public static let mainGraph: CGFloat = 170
    public static let cardGraph: CGFloat = 52
    /// Verlauf im Popover eines Menüleisten-Elements (TM17).
    public static let popoverGraph: CGFloat = 70
    /// Übersicht der Menüleiste (#495): Lastring je Kern, Wertring (GPU, Arbeitsspeicher), gespiegelter Verlauf.
    public static let coreRing: CGFloat = 18
    public static let valueRing: CGFloat = 60
    public static let overviewMirror: CGFloat = 32
    public static let panelGraph: CGFloat = 120
    public static let coreCell: CGFloat = 30
    public static let gpuCell: CGFloat = 12
    public static let peilPoint: CGFloat = 3.5
    /// Mindestbreite eines Messfelds; schmaler bricht die Reihe um.
    public static let measureField: CGFloat = 124
    public static let columnNarrow: CGFloat = 270
    public static let columnWide: CGFloat = 360
    public static let columnRadar: CGFloat = 400
    /// Höhe des Erreichbarkeitsradars.
    public static let radar: CGFloat = 280
    /// Höhe des Belegungsbands.
    public static let band: CGFloat = 12
    /// Farbfeld der Legende eines Bands (zeigt die Deckkraftstufe, daher höher als der Legendenstrich).
    public static let bandSwatch = CGSize(width: 12, height: 8)
    /// Spalten der Ordnerleiter: Spur (Anteil am Elternordner) und Größe, in allen Zeilen gleich breit.
    public static let ladderSpur: CGFloat = 96
    public static let ladderValue: CGFloat = 72
    /// Höhe einer einzeiligen Tabellenzeile (§3.7).
    public static let row: CGFloat = 28
    /// Mindesthöhe der rollenden Zeilen einer Tabelle (`InstrumentTable`): vier Zeilen. Ohne sie ließ der App-Verlauf
    /// bei 900 × 652 pt mit Seitenleiste der Tabelle eine Zeile (Nachbewertung 2026.11.9/1531, Sollte 1).
    public static let tableRowsMinimum: CGFloat = row * 4
}

/// Schriften (§2.7); große Werte in SF Rounded mit festen Ziffern.
public enum InstrumentFont {
    public static let display = Font.system(size: 30, weight: .semibold)
    public static let verdict = Font.system(.title2, design: .rounded, weight: .semibold)
    public static let bigNumber = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    public static let valueLarge = Font.system(.title2, design: .rounded, weight: .semibold).monospacedDigit()
    public static let value = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
    public static let title = Font.headline
    public static let tileValue = Font.system(.callout, design: .rounded, weight: .semibold).monospacedDigit()
    public static let body = Font.callout
    public static let numeric = Font.callout.monospacedDigit()
    public static let code = Font.callout.monospaced()
    public static let label = Font.caption
    public static let micro = Font.caption2
    public static let rowIcon = Font.system(size: 11)
}

/// Deckkraft der Menüleisten-Elemente (TM17): einfarbige Vorlagenbilder, nur die Deckkraft zählt – das System färbt sie
/// in heller und dunkler Menüleiste ein. „Kontrast erhöhen“ macht Ränder kräftiger.
public enum MenuBarInk {
    public static let full = 1.0
    /// Kurzbezeichnung über dem Wert.
    public static let tag = 0.7
    /// Grund des Messfelds.
    public static let well = 0.12
    public static let wellBorder = 0.45
    public static let wellBorderIncreased = 0.8
    /// Fläche unter der Kurve.
    public static let area = 0.5
    /// Mittellinie des gespiegelten Verlaufs.
    public static let midline = 0.35
    /// Leere Rinne von Pegel und Thermometer.
    public static let track = 0.25
    /// Umriss von Thermometer und Akku.
    public static let outline = 0.6
    public static let outlineIncreased = 0.9
    /// Pol des Akkus.
    public static let tip = 0.55

    public static func color(_ opacity: Double) -> CGColor { nsColor(opacity).cgColor }

    public static func nsColor(_ opacity: Double) -> NSColor { NSColor.black.withAlphaComponent(opacity) }
}
