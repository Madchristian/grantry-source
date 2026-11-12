import SwiftUI

// Zeilen des Speichers im Lagebild (LB-4.3, #549; Entwurf LB-4.1, #547, Spec 2026-11-10 § 11.4 c): Kopf einer Kategorie
// mit Spur des Anteils für `DisclosureSection(togglesOnHead: true)` und ein Eintrag nur zum Bericht. Zeichnet nur bei
// neuen Daten, ohne Übergang.

/// Kopf einer Speicher-Kategorie: Titel, Satz, Status und Risiko als Chips, Größe und darunter die Spur des Anteils am
/// Aufräumbaren in der Farbe Datenträger. Liest VoiceOver nicht selbst: `DisclosureSection` fasst den Kopf zu einem Knopf
/// mit `spokenValue` als Wert zusammen.
public struct StorageCategoryHead: View {
    let title: String
    let summary: String
    let risk: StatusItem
    let status: StatusItem?
    let size: String
    let share: Double?

    @Environment(\.self) private var environment

    /// - Parameter share: Anteil am Aufräumbaren; `nil` ohne bekannte Größe (leere Bahn).
    public init(title: String, summary: String, risk: StatusItem, status: StatusItem?, size: String, share: Double?) {
        self.title = title
        self.summary = summary
        self.risk = risk
        self.status = status
        self.size = size
        self.share = share
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(spacing: InstrumentSpacing.cell) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    Text(verbatim: title).font(InstrumentFont.body.weight(.medium))
                    if !summary.isEmpty {
                        Text(verbatim: summary).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: InstrumentSpacing.group)
                if let status { StatusChip(status, isSmall: true) }
                StatusChip(risk, isSmall: true)
                Text(verbatim: size).font(InstrumentFont.numeric)
            }
            Spur(fraction: share, color: environment.instrumentColor(.diskWrite))
                .frame(height: InstrumentSize.spurCard)
        }
        .padding(.trailing, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }

    /// „18,6 GB, 65 % des Aufräumbaren, Risiko gering, nicht erfasst, Satz“.
    public nonisolated static func spokenValue(size: String, share: Double?, risk: StatusItem, status: StatusItem?,
                                               summary: String) -> String {
        let percent = share.map {
            String(localized: "\($0.formatted(.percent.precision(.fractionLength(0)))) des Aufräumbaren")
        }
        return [size, percent, risk.text, status?.text, summary.isEmpty ? nil : summary]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// Eintrag ohne Häkchen (nur Bericht oder gesperrt): Symbol, Name, Grund und Größe, rechts ein Verweis wie „Befehl
/// kopieren“ oder „Im Finder zeigen“. VoiceOver liest den Namen als Beschriftung, Grund und Größe als Wert; der Verweis
/// bleibt ein eigener Knopf.
public struct ReportRow<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let size: String
    let actions: Actions

    public init(symbol: String, title: String, detail: String, size: String, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.size = size
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            Image(systemName: symbol).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body).lineLimit(1)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityReading(Text(verbatim: title), value: Text(verbatim: Self.spokenValue(detail: detail, size: size)))
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: size).font(InstrumentFont.numeric).foregroundStyle(.instrumentSecondary)
                .accessibilityHidden(true)
            HStack(spacing: InstrumentSpacing.group) { actions }
                .buttonStyle(.link)
                .font(InstrumentFont.label)
                .fixedSize()
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }

    /// „Grund, Größe“; ohne Grund nur die Größe.
    nonisolated static func spokenValue(detail: String, size: String) -> String {
        detail.isEmpty ? size : "\(detail), \(size)"
    }
}

extension ReportRow where Actions == EmptyView {
    public init(symbol: String, title: String, detail: String, size: String) {
        self.init(symbol: symbol, title: title, detail: detail, size: size) { EmptyView() }
    }
}
