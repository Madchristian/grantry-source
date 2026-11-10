import Foundation
import GrantryShared

/// Ein Ereignis im Wachbuch (Spec 2026-11-08 §5.1): ein Befund mit Beginn und Ende, eine Änderung aus dem Verlauf oder
/// ein Systemereignis. Ein späterer Eintrag mit derselben `id` ersetzt den früheren – so bekommt ein Befund sein Ende.
public struct WatchbookEvent: Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case finding, change, system
    }

    /// Ton eines Befunds (Spec §4.3).
    public enum Tone: String, CaseIterable, Hashable, Sendable {
        case finding, critical
    }

    static let maximumTypeLength = 40
    static let maximumSummaryLength = 240

    public let id: UUID
    public let kind: Kind
    /// Art innerhalb der Gattung (Befundart, Quelle der Änderung, Art des Systemereignisses), maschinenlesbar: nur
    /// ASCII-Buchstaben, Ziffern, `.`, `-` und `_`.
    public let type: String
    public let start: Date
    /// Ende; bei Augenblicksereignissen gleich `start`, bei laufenden Befunden `nil`.
    public let end: Date?
    public let tone: Tone?
    /// Hauptverursacher, falls bekannt – Namen nach derselben Regel wie die Verbraucher (`WatchbookSubject`).
    public let subject: WatchbookSubject?
    /// PID und Startzeit des Verursachers für den Sprung nach Details (TM-12.6); nur bei eigenen Programmen und
    /// Systemprozessen, nie bei „Andere Konten“.
    public let process: ProcessKey?
    /// Ein Satz (Grund, Beschreibung); einzeilig und begrenzt.
    public let summary: String

    public init(id: UUID = UUID(), kind: Kind, type: String, start: Date, end: Date?, tone: Tone?,
                subject: WatchbookSubject?, process: ProcessKey? = nil, summary: String) {
        self.id = id
        self.kind = kind
        self.type = Self.machineReadable(type)
        self.start = start
        self.end = end
        self.tone = tone
        self.subject = subject
        self.process = subject?.name == nil ? nil : process
        self.summary = String(DisplayText.singleLine(summary).prefix(Self.maximumSummaryLength))
    }

    /// Derselbe Eintrag mit Ende (etwa wenn ein Befund abklingt).
    public func ended(at end: Date) -> WatchbookEvent {
        WatchbookEvent(id: id, kind: kind, type: type, start: start, end: end, tone: tone, subject: subject,
                       process: process, summary: summary)
    }

    /// Ob das Ereignis in `range` fällt; ein laufender Befund reicht bis zum Ende jedes späteren Zeitraums.
    public func overlaps(_ range: Range<Date>) -> Bool {
        guard start < range.upperBound else { return false }
        guard let end else { return true }
        return end == start ? start >= range.lowerBound : end > range.lowerBound
    }

    private static func machineReadable(_ type: String) -> String {
        let allowed = type.unicodeScalars.prefix(maximumTypeLength).map { scalar -> Character in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || ".-_".unicodeScalars
                .contains(scalar)) ? Character(scalar) : "_"
        }
        return String(allowed)
    }
}

/// Schnittstelle zum Befund-Modell (TM-12.1) und zu anderen Quellen: Sie liefern ihren Eintrag im Wachbuch, ohne dass
/// der Speicher ihre Typen kennt.
public protocol WatchbookEventConvertible {
    var watchbookEvent: WatchbookEvent { get }
}
