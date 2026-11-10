import SwiftUI

/// Inhalt des Bereichs „Erweiterungen“ (TM-13.5, Spec 2026-11-08 § 5.2) als fertige Texte und Töne: Die Darstellung in
/// ManagerKit (`ExtensionPresentation`) rechnet, die App ordnet zu (wie Belegung und Verbindungen).
public struct ExtensionBoardContent: Equatable, Sendable {
    /// Alle Rechte-Schichten von innen nach außen, unabhängig von Suche und Filter – für Radar und Schichtenliste.
    public var layers: [ExtensionLayerContent]
    /// Die Schichten mit den Zeilen nach Suche und Filter für die Tabelle; Schichten ohne Treffer fehlen.
    public var sections: [ExtensionLayerContent]
    /// Wert im Peilkopf der Rechte-Schichten, etwa die Zahl der Erweiterungen.
    public var radarValue: String
    /// „5 von 8“ neben dem Filter.
    public var shownText: String
    /// Hinweis, wenn eine Liste nicht vollständig gelesen wurde; sonst `nil`.
    public var notice: String?
    /// Ruhiges Urteil statt Tabelle, wenn keine fremde Erweiterung da ist; sonst `nil`.
    public var calm: ExtensionCalmContent?

    public init(layers: [ExtensionLayerContent], sections: [ExtensionLayerContent], radarValue: String,
                shownText: String, notice: String? = nil, calm: ExtensionCalmContent? = nil) {
        self.layers = layers
        self.sections = sections
        self.radarValue = radarValue
        self.shownText = shownText
        self.notice = notice
        self.calm = calm
    }

    /// Mindestens eine Erweiterung mit Befund (auffällig oder kritisch).
    public var hasFinding: Bool { layers.contains { $0.findingCount > 0 } }
}

/// Eine Rechte-Schicht: Name, kurzer Ringtitel, ein Satz, was sie bedeutet, und ihre Erweiterungen.
public struct ExtensionLayerContent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Kurzer Titel am Ring des Radars („im Kern“).
    public let ringTitle: String
    public let explanation: String
    public let rows: [ExtensionRowContent]
    /// Zusatz zur Schicht, etwa ausgeblendete Plug-ins von Apple.
    public let note: String?

    public init(id: String, title: String, ringTitle: String, explanation: String, rows: [ExtensionRowContent],
                note: String? = nil) {
        self.id = id
        self.title = title
        self.ringTitle = ringTitle
        self.explanation = explanation
        self.rows = rows
        self.note = note
    }

    public var findingCount: Int { rows.count(where: \.isFinding) }
}

/// Eine Erweiterung als Tabellenzeile und Echo im Radar.
public struct ExtensionRowContent: Identifiable, Hashable, Sendable {
    public let id: String
    /// SF Symbol der Art.
    public let symbol: String
    public let title: String
    /// Name der Art, etwa „Endpoint Security“.
    public let kind: String
    /// Hersteller (Entwicklername oder App), „–“ wenn unbekannt.
    public let vendor: String
    /// Team-ID oder Herkunft in einer Zeile.
    public let vendorDetail: String
    public let version: String
    public let state: StatusItem
    /// Bewertung: kritisch, auffällig, Hinweis oder akzeptiert; `nil` heißt unauffällig.
    public let rating: StatusItem?
    /// Kurzname am Echo im Radar.
    public let radarLabel: String

    public init(id: String, symbol: String, title: String, kind: String, vendor: String, vendorDetail: String,
                version: String, state: StatusItem, rating: StatusItem?, radarLabel: String) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.kind = kind
        self.vendor = vendor
        self.vendorDetail = vendorDetail
        self.version = version
        self.state = state
        self.rating = rating
        self.radarLabel = radarLabel
    }

    /// Auffällig oder kritisch – mit Befund-Punkt vor dem Namen und im Radar.
    public var isFinding: Bool { rating.map { [.finding, .critical].contains($0.tone) } ?? false }

    /// VoiceOver: „Name, Art, Hersteller, Zustand, Bewertung“.
    var accessibilityLabel: String {
        ([title, kind, vendor, state.text] + [rating?.text].compactMap(\.self)).joined(separator: ", ")
    }
}

/// Detail der gewählten Erweiterung: was ihre Art darf, Befunde und Herkunft. Aktionen liefert die Ansicht.
public struct ExtensionDetailContent: Equatable, Sendable {
    /// Angabe der Herkunft: Titel, Wert und optional ein Ton (etwa „fehlt“ in Bernstein).
    public struct Fact: Hashable, Sendable {
        public let title: String
        public let value: String
        public let tone: StatusTone?
        /// Kennungen wie Team- und Bundle-ID in Festbreitenschrift.
        public let isCode: Bool

        public init(title: String, value: String, tone: StatusTone? = nil, isCode: Bool = false) {
            self.title = title
            self.value = value
            self.tone = tone
            self.isCode = isCode
        }
    }

    public let id: String
    public let symbol: String
    public let title: String
    /// „Endpoint Security · von Wachposten“.
    public let subtitle: String
    public let state: StatusItem
    public let rating: StatusItem?
    /// Ein Satz, was Erweiterungen dieser Art dürfen.
    public let permission: String
    /// Befunde und Hinweise der Sicherheitsbewertung mit Ton.
    public let findings: [StatusItem]
    /// Satz zur eigenen Einschätzung, wenn es etwas zu akzeptieren gibt oder die Erweiterung akzeptiert ist; sonst `nil`.
    public let acceptance: String?
    /// Herkunft: Hersteller, Kennungen, Version, Signatur, zugehörige App, erstmals gesehen, Pfad.
    public let facts: [Fact]

    public init(id: String, symbol: String, title: String, subtitle: String, state: StatusItem, rating: StatusItem?,
                permission: String, findings: [StatusItem], acceptance: String?, facts: [Fact]) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.rating = rating
        self.permission = permission
        self.findings = findings
        self.acceptance = acceptance
        self.facts = facts
    }
}

/// Ruhiges Urteil ohne fremde Erweiterungen (§3.11: keine leere Fläche): was geprüft wurde und was ausgeblendet ist.
public struct ExtensionCalmContent: Equatable, Sendable {
    public let title: String
    public let reason: String
    /// Je Liste ein Satz, was Grantry geprüft hat.
    public let checks: [String]
    public let note: String?

    public init(title: String, reason: String, checks: [String], note: String? = nil) {
        self.title = title
        self.reason = reason
        self.checks = checks
        self.note = note
    }
}
