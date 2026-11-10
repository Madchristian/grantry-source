import SwiftUI

/// Inhalt des Tabs „Wachbuch“ (TM-12.5, Spec 2026-11-08 § 5.1) als fertige Spalten, Texte und Töne: Die Darstellung in
/// ManagerKit (`WatchbookPresentation`) rechnet, die App ordnet zu (wie Erweiterungen und Belegung). Zeitpunkte stehen als
/// Anteil am Zeitraum (0 links, 1 „jetzt“), Werte als verdichtete Spalten – je Bildpunktspalte höchstens ein Wert
/// (§ 4.4 Regel 5).
public enum WatchbookBoardState: Equatable, Sendable {
    /// „Wachbuch führen“ ist aus.
    case off
    /// Die Aufzeichnung wird gelesen (nur bis zum ersten Bild).
    case loading
    /// An, aber im Zeitraum noch nichts aufgezeichnet.
    case empty
    case recorded(WatchbookTimelineContent)
}

/// Minimum, Maximum und Mittel einer Spalte.
public struct TimelineValue: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let mean: Double

    public init(minimum: Double, maximum: Double, mean: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
    }
}

/// Spuren, Ereignisse, Thermikband und Zeitachse eines Zeitraums.
public struct WatchbookTimelineContent: Equatable, Sendable {
    public var lanes: [WatchbookLaneContent]
    public var marks: [WatchbookMarkContent]
    /// Ton je Spalte für das Thermikband: `neutral` = normal (ohne Farbe), `finding` bzw. `critical` = auffällig,
    /// `nil` = nicht gemessen.
    public var thermal: [StatusTone?]
    public var axis: [WatchbookAxisTick]
    /// Spalten je Pfeiltaste beim Verschieben der Zeitmarke.
    public var markerStep: Int
    /// „2 Befunde · 4 Änderungen“ neben „Ereignisse“.
    public var eventSummary: String

    public init(lanes: [WatchbookLaneContent], marks: [WatchbookMarkContent], thermal: [StatusTone?],
                axis: [WatchbookAxisTick], markerStep: Int, eventSummary: String) {
        self.lanes = lanes
        self.marks = marks
        self.thermal = thermal
        self.axis = axis
        self.markerStep = max(markerStep, 1)
        self.eventSummary = eventSummary
    }

    /// Spalten des Zeitraums (gleich für alle Spuren).
    public var columnCount: Int { max(lanes.first?.columnCount ?? thermal.count, thermal.count) }
}

/// Eine Verlaufsspur (§ 3.4): CPU und Arbeitsspeicher als Linie, Netz und Datenträger als Spiegel.
public struct WatchbookLaneContent: Identifiable, Equatable, Sendable {
    public enum Graph: Equatable, Sendable {
        /// Eine Reihe von 0 bis `upperBound`.
        case line(values: [TimelineValue?], upperBound: Double, hue: InstrumentHue)
        /// Oben empfangen bzw. lesen, unten gesendet bzw. schreiben, gemeinsame Skala.
        case mirror(upper: [TimelineValue?], lower: [TimelineValue?], upperBound: Double, upperHue: InstrumentHue,
                    lowerHue: InstrumentHue)
    }

    public let id: String
    public let title: String
    public let hue: InstrumentHue
    public let graph: Graph

    public init(id: String, title: String, hue: InstrumentHue, graph: Graph) {
        self.id = id
        self.title = title
        self.hue = hue
        self.graph = graph
    }

    var columnCount: Int {
        switch graph {
        case .line(let values, _, _): values.count
        case .mirror(let upper, let lower, _, _, _): max(upper.count, lower.count)
        }
    }

    /// Mittelwerte der Hauptreihe für den Trend (VoiceOver).
    var trendValues: [Double?] {
        switch graph {
        case .line(let values, _, _), .mirror(let values, _, _, _, _): values.map { $0?.mean }
        }
    }

    var upperBound: Double {
        switch graph {
        case .line(_, let upperBound, _), .mirror(_, _, let upperBound, _, _): upperBound
        }
    }
}

/// Eine Marke der Ereignisleiste: Befund über seine Dauer, Änderung oder Systemereignis als Augenblick oder Zeitraum.
public struct WatchbookMarkContent: Identifiable, Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        /// Befund in Bernstein bzw. kritisch; Spanne über die Dauer.
        case finding, critical
        /// Änderung oder Systemereignis: neutrale Marke mit dem Symbol der Quelle.
        case change, system
    }

    public let id: String
    public let style: Style
    /// Beginn als Anteil am Zeitraum; vor dem Zeitraum begonnene Befunde beginnen bei 0.
    public let start: Double
    /// Ende als Anteil; gleich `start` bei Augenblicken, 1 bei laufenden Befunden.
    public let end: Double
    /// SF Symbol der Quelle (Änderungen, Systemereignisse).
    public let symbol: String?
    /// Ein Satz für VoiceOver und die Ereignisliste: Art, Zeit, Grund.
    public let text: String

    public init(id: String, style: Style, start: Double, end: Double, symbol: String? = nil, text: String) {
        self.id = id
        self.style = style
        self.start = min(max(start, 0), 1)
        self.end = min(max(end, self.start), 1)
        self.symbol = symbol
        self.text = text
    }

    public var isFinding: Bool { style == .finding || style == .critical }
}

/// Beschriftung der Zeitachse an einem Anteil des Zeitraums.
public struct WatchbookAxisTick: Hashable, Sendable {
    public let position: Double
    public let label: String

    public init(position: Double, label: String) {
        self.position = position
        self.label = label
    }
}

/// Was die Spalte unter der Zeitmarke zeigt – oder ohne Zeitmarke der neueste Stand: Werte der Spuren in derselben
/// Reihenfolge wie `WatchbookTimelineContent.lanes`, Thermik und Zeitpunkt.
public struct WatchbookReadout: Equatable, Sendable {
    public var time: String
    public var laneValues: [String]
    public var thermal: String

    public init(time: String, laneValues: [String], thermal: String) {
        self.time = time
        self.laneValues = laneValues
        self.thermal = thermal
    }
}

/// Ein Sprung zum zuständigen Bereich (Prozess, Verlaufseintrag, Autostart, Erweiterung, Verbindungen). Die App ordnet
/// `id` ihrem Ziel zu; ist das Ziel nicht mehr da (Prozess beendet, PID neu vergeben), steht statt des Knopfs `note`.
public struct WatchbookJumpContent: Hashable, Sendable {
    public let id: String
    /// „In Details zeigen“, „Im Verlauf zeigen“ …
    public let title: String
    /// Warum es kein Ziel gibt, etwa „Prozess läuft nicht mehr“; dann kein Knopf.
    public let note: String?

    public init(id: String, title: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.note = note
    }
}

/// Ein Eintrag im Panel „Zu diesem Zeitpunkt“: ein laufender Befund oder eine Änderung bzw. ein Systemereignis ±5 min.
public struct WatchbookMomentEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let style: WatchbookMarkContent.Style
    /// SF Symbol der Quelle (Änderungen, Systemereignisse).
    public let symbol: String?
    /// „Dauerlast“, „App installiert“.
    public let title: String
    /// „seit 15:02“, „15:02 bis 15:11“, „15:22“.
    public let time: String
    /// Grund bzw. Beschreibung in einem Satz.
    public let detail: String
    public let jump: WatchbookJumpContent?

    public init(id: String, style: WatchbookMarkContent.Style, symbol: String? = nil, title: String, time: String,
                detail: String, jump: WatchbookJumpContent? = nil) {
        self.id = id
        self.style = style
        self.symbol = symbol
        self.title = title
        self.time = time
        self.detail = detail
        self.jump = jump
    }

    public var isFinding: Bool { style == .finding || style == .critical }
}

/// Einer der größten Verbraucher an der Zeitmarke: Name (oder „Andere Konten“), Art, Wert und Anteil für die Spur.
public struct WatchbookConsumerContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Kleiner Chip hinter dem Namen: „System“; leer für eigene Programme.
    public let badge: String
    public let value: String
    /// Anteil für die Spur (0…1); `nil` ohne Spur.
    public let fraction: Double?

    public init(id: String, name: String, badge: String = "", value: String, fraction: Double?) {
        self.id = id
        self.name = name
        self.badge = badge
        self.value = value
        self.fraction = fraction
    }
}

/// Inhalt des Panels „Zu diesem Zeitpunkt“ (Spec 2026-11-08 § 5.1): Werte, größte Verbraucher, laufende Befunde und
/// Änderungen ±5 min an der Zeitmarke.
public struct WatchbookMomentContent: Equatable, Sendable {
    /// Zeitpunkt im Peilkopf, „So 15:06“.
    public var time: String
    /// Werte, die die Spuren nicht zeigen (GPU, Speicherdruck, Swap, Thermik, Akku, Leistung); nur gemessene.
    public var values: [WatchbookMomentValue]
    public var cpuConsumers: [WatchbookConsumerContent]
    public var memoryConsumers: [WatchbookConsumerContent]
    /// Statt der Verbraucher, etwa „Für diesen Zeitpunkt nicht aufgezeichnet“; `nil` mit Verbrauchern.
    public var consumersNote: String?
    public var findings: [WatchbookMomentEntry]
    public var changes: [WatchbookMomentEntry]

    public init(time: String, values: [WatchbookMomentValue], cpuConsumers: [WatchbookConsumerContent],
                memoryConsumers: [WatchbookConsumerContent], consumersNote: String? = nil,
                findings: [WatchbookMomentEntry], changes: [WatchbookMomentEntry]) {
        self.time = time
        self.values = values
        self.cpuConsumers = cpuConsumers
        self.memoryConsumers = memoryConsumers
        self.consumersNote = consumersNote
        self.findings = findings
        self.changes = changes
    }
}

/// Ein Messfeld im Panel „Zu diesem Zeitpunkt“.
public struct WatchbookMomentValue: Hashable, Sendable {
    public let title: String
    public let value: String

    public init(title: String, value: String) {
        self.title = title
        self.value = value
    }
}

/// Eine Zeile der Tabelle „Befunde“ (§ 3.7): Beginn, Dauer, Art, Grund, Hauptverursacher.
public struct WatchbookFindingRowContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let isCritical: Bool
    /// „So 15:02“.
    public let start: String
    /// „9 min“, „läuft · 1 h 19 min“.
    public let duration: String
    /// „Dauerlast“.
    public let kind: String
    public let reason: String
    /// Name des Hauptverursachers; „–“ ohne.
    public let cause: String

    public init(id: String, isCritical: Bool, start: String, duration: String, kind: String, reason: String,
                cause: String) {
        self.id = id
        self.isCritical = isCritical
        self.start = start
        self.duration = duration
        self.kind = kind
        self.reason = reason
        self.cause = cause
    }

    var accessibilityLabel: String {
        let kind = isCritical ? String(localized: "\(kind), kritisch") : kind
        return [kind, start, duration, reason, cause == "–" ? "" : String(localized: "Verursacher \(cause)")]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
