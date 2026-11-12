import SwiftUI

// Zeilenkopf der Liste-Detail-Ansichten (LB-1.2, #536; Standard §3.7, §3.8): Symbol im Kreis mit Befund-Punkt, Name und
// Detail, rechts Badges und Zustandschip. Gemeinsam für die Auswahlliste (`InstrumentList`), die Einträge im Detail
// (`DetailItem`) und den Zeilenkopf der Prüfzeile (`CheckRow`).

/// Badge eines Eintrags („prüfen“, „neu“, „aufräumen“) als kleiner Zustandschip (§3.8); `spoken` liest VoiceOver, etwa
/// mit Schweregrad.
public struct InstrumentBadge: Hashable, Sendable {
    public let title: String
    public let tone: StatusTone
    public let spoken: String

    public init(_ title: String, tone: StatusTone, spoken: String? = nil) {
        self.title = title
        self.tone = tone
        self.spoken = spoken ?? title
    }
}

/// Badges eines Eintrags nebeneinander als kleine Zustandschips; jeder Chip liest seine Sprechform.
public struct BadgeChips: View {
    let badges: [InstrumentBadge]

    public init(_ badges: [InstrumentBadge]) {
        self.badges = badges
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            ForEach(badges, id: \.self) { badge in
                StatusChip(badge.title, tone: badge.tone, isSmall: true)
                    .accessibilityLabel(Text(verbatim: badge.spoken))
            }
        }
    }
}

/// Inhalt einer Zeile: Symbol, Name, Detail, Badges, Zustand und ob Grantry der Eintrag auffällt. Gleichwertig vergleichbar,
/// damit unveränderte Zeilen nicht neu zeichnen (Spec §8 Punkt 5).
public struct InstrumentRowContent: Hashable, Sendable {
    public let symbol: String
    public let title: String
    public let detail: String
    public let badges: [InstrumentBadge]
    public let status: StatusItem?
    public let finding: Bool

    public init(symbol: String, title: String, detail: String, badges: [InstrumentBadge] = [],
                status: StatusItem? = nil, finding: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.badges = badges
        self.status = status
        self.finding = finding
    }

    /// Wert für VoiceOver neben dem Namen als Beschriftung: „auffällig, Zustand, Badges. Detail“ – nie nur der Titel (#563).
    public var spokenValue: String {
        let state = ([finding ? String(localized: "auffällig") : nil, status?.text] + badges.map(\.spoken))
            .compactMap { $0 }
        guard !state.isEmpty else { return detail }
        let joined = state.joined(separator: ", ")
        return detail.isEmpty ? joined : "\(joined). \(detail)"
    }
}

/// Symbol eines Eintrags im Kreis (§3.10a); im Detailkopf groß. Dekorativ, die Zeile liest den Namen.
public struct InstrumentRowIcon: View {
    let symbol: String
    let size: CGFloat

    public init(symbol: String, size: CGFloat = InstrumentSize.rowIconTall) {
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(size > InstrumentSize.rowIconTall ? InstrumentFont.title : InstrumentFont.rowIcon)
            .foregroundStyle(.instrumentSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(.quaternary))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Befund-Punkt oben rechts am Symbol wie im App-Symbol (Spec §11.1 b); auch für eigene Symbole wie App-Symbole.
    public func instrumentFindingDot(_ shown: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if shown { FindingDot(size: InstrumentSize.findingDotSmall) }
        }
    }
}

/// Zeile aus `InstrumentRowContent`: Symbol mit Befund-Punkt, Name und Detail, rechts Badges und Zustandschip. Das Symbol
/// ist austauschbar (App-Symbole); ohne Angabe das SF-Symbol im Kreis.
public struct InstrumentRowLabel<Icon: View>: View {
    let content: InstrumentRowContent
    let icon: Icon

    public init(_ content: InstrumentRowContent, @ViewBuilder icon: () -> Icon) {
        self.content = content
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            icon.instrumentFindingDot(content.finding)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: content.title).font(InstrumentFont.body.weight(.medium)).lineLimit(1)
                if !content.detail.isEmpty {
                    Text(verbatim: content.detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: InstrumentSpacing.group)
            BadgeChips(content.badges)
            if let status = content.status { StatusChip(status) }
        }
    }
}

extension InstrumentRowLabel where Icon == InstrumentRowIcon {
    public init(_ content: InstrumentRowContent) {
        self.init(content) { InstrumentRowIcon(symbol: content.symbol) }
    }
}
