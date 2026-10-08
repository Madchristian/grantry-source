import Foundation

/// Datenmengen und -raten mit skalierter Einheit (Basis 1000 wie der Finder): „512 B/s“, „1,2 KB/s“, „34 MB“.
public enum TrafficFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]
    private static let locale = Locale(identifier: "de_DE")

    public static func bytes(_ count: UInt64) -> String { scaled(Double(count)) }

    public static func rate(_ bytesPerSecond: Double) -> String { "\(scaled(bytesPerSecond))/s" }

    /// Unter 10 einer Einheit mit einer Nachkommastelle, sonst ganzzahlig; Bytes immer ganzzahlig. Erst gerundet, dann
    /// die Einheit gewählt – 999 999 B ergibt „1,0 MB“, nicht „1000 KB“.
    private static func scaled(_ value: Double) -> String {
        var value = max(0, value)
        var unit = 0
        while true {
            let (rounded, digits) = rounded(value, unit: unit)
            guard rounded >= 1000, unit < units.count - 1 else {
                let number = rounded.formatted(.number.precision(.fractionLength(digits)).grouping(.never)
                    .locale(locale))
                return "\(number) \(units[unit])"
            }
            value /= 1000
            unit += 1
        }
    }

    /// Der angezeigte Wert und seine Nachkommastellen; rundet ein Wert unter 10 auf 10, gilt er als ganzzahlig.
    private static func rounded(_ value: Double, unit: Int) -> (value: Double, digits: Int) {
        let tenths = (value * 10).rounded() / 10
        guard unit > 0, tenths < 10 else { return (value.rounded(), 0) }
        return (tenths, 1)
    }
}

/// Warum die Netzwerkaktivität keine Zahlen zeigt.
public enum NetworkActivityFailure: Hashable, Sendable {
    /// nettop ließ sich nicht starten.
    case unavailable(reason: String)
    /// nettop schreibt ein unbekanntes Format.
    case unrecognizedFormat
    /// nettop endete mehrmals in Folge ohne Messung oder ohne stabil zu laufen (Anzahl je nach Ursache, siehe
    /// `NettopSampler`).
    case endedRepeatedly

    init(_ error: NettopSamplerError) {
        switch error {
        case .launchFailed(let reason): self = .unavailable(reason: reason)
        case .unrecognizedFormat: self = .unrecognizedFormat
        case .endedRepeatedly: self = .endedRepeatedly
        }
    }
}

/// Hinweis über der Aktivität, gestaltet wie die Abdeckungsleiste (#142): Fehlerzustand ohne Zahlen oder teilweise
/// unlesbare Ausgabe.
public struct NetworkActivityNotice: Hashable, Sendable {
    public let tone: PresentationTone
    public let systemImage: String
    public let headline: String
    public let reasons: [String]
    /// „Erneut versuchen“ kann helfen (nicht bei unbekanntem Format).
    public let offersRetry: Bool

    /// - Parameter systemVersion: macOS-Version für den Formathinweis („27.0.1“).
    public static func make(failure: NetworkActivityFailure?, skippedLineCount: Int, systemVersion: String) -> Self? {
        switch failure {
        case .unavailable(let reason):
            return Self(tone: .critical, systemImage: "xmark.circle.fill",
                        headline: "Netzwerkaktivität nicht verfügbar – nettop ließ sich nicht starten",
                        reasons: [reason], offersRetry: true)
        case .unrecognizedFormat:
            return Self(tone: .critical, systemImage: "xmark.circle.fill",
                        headline: "Ausgabeformat von nettop nicht erkannt (macOS \(systemVersion))",
                        reasons: ["Ohne bekanntes Format zeigt Grantry keine Zahlen."], offersRetry: false)
        case .endedRepeatedly:
            return Self(tone: .critical, systemImage: "xmark.circle.fill",
                        headline: "Netzwerkaktivität nicht verfügbar – nettop wurde wiederholt beendet",
                        reasons: [], offersRetry: true)
        case nil:
            guard skippedLineCount > 0 else { return nil }
            let lines = skippedLineCount == 1 ? "1 Verbindungszeile" : "\(skippedLineCount) Verbindungszeilen"
            return Self(tone: .warning, systemImage: "circle.lefthalf.filled", headline: "Teilweise gelesen",
                        reasons: ["\(lines) von nettop nicht lesbar – diese Verbindungen fehlen."], offersRetry: false)
        }
    }
}
