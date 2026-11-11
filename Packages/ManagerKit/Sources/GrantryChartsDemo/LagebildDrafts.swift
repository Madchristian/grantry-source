import GrantryCharts
import SwiftUI

// Entwurf LB-1.1 (#535, Spec docs/superpowers/specs/2026-11-10-lagebild-altansichten-design.md § 4.2): die Bausteine, die
// den alten Ansichten fehlen, nur aus vorhandenen Tokens und Bausteinen abgeleitet – Auswahlliste, Detail-Panel,
// Hinweiszeile, Banner, Häkchenzeile, Fortschritt als Spur. Nur Galerie mit festen Beispieldaten, keine Datenanbindung.
// Die zentralen Fassungen entstehen nach der Abnahme in LB-1.2 (#536) unter `GrantryCharts`; der Name in Klammern ist
// jeweils der dort vorgesehene.

// MARK: - Zeilenkopf und Badges

/// Badge eines Eintrags („prüfen“, „neu“, „aufräumen“) als kleiner Zustandschip (`BadgeChips`).
struct DraftBadge: Hashable {
    let title: String
    let tone: StatusTone
    /// Für VoiceOver, etwa mit Schweregrad.
    let spoken: String

    static let review = DraftBadge(title: "prüfen", tone: .finding, spoken: "prüfen, mittlerer Schweregrad")
    static let reviewHigh = DraftBadge(title: "prüfen", tone: .critical, spoken: "prüfen, hoher Schweregrad")
    static let new = DraftBadge(title: "neu", tone: .neutral, spoken: "neu")
    static let cleanup = DraftBadge(title: "aufräumen", tone: .neutral, spoken: "aufräumen")
}

/// Badges eines Eintrags nebeneinander (`BadgeChips`).
struct DraftBadgeChips: View {
    let badges: [DraftBadge]

    var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            ForEach(badges, id: \.self) { badge in
                StatusChip(badge.title, tone: badge.tone, isSmall: true)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Symbol eines Eintrags im Kreis wie in der Prüfzeile; bei Befund der Bernstein-Punkt oben rechts wie im App-Symbol.
struct DraftRowIcon: View {
    let symbol: String
    var finding = false
    var size = InstrumentSize.rowIconTall

    var body: some View {
        Image(systemName: symbol)
            .font(size > InstrumentSize.rowIconTall ? InstrumentFont.title : InstrumentFont.rowIcon)
            .foregroundStyle(.instrumentSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(.quaternary))
            .overlay(alignment: .topTrailing) {
                if finding { FindingDot(size: InstrumentSize.findingDotSmall) }
            }
            .accessibilityHidden(true)
    }
}

/// Inhalt einer Zeile: Symbol, Name und Detail, rechts Badges und ein Zustandschip. Gemeinsam für Auswahlliste und die
/// Einträge im Detail-Panel.
struct DraftRowHead: View {
    let symbol: String
    let title: String
    let detail: String
    var badges: [DraftBadge] = []
    var status: StatusItem?
    var finding = false

    var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            DraftRowIcon(symbol: symbol, finding: finding)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.medium)).lineLimit(1)
                Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
            Spacer(minLength: InstrumentSpacing.group)
            DraftBadgeChips(badges: badges)
            if let status { StatusChip(status) }
        }
    }

    /// VoiceOver: Name als Beschriftung, Zustand und Detail als Wert (Lehre aus #563: nie nur der Titel).
    var spokenValue: String {
        let state = ([finding ? "auffällig" : nil, status?.text] + badges.map(\.spoken)).compactMap { $0 }
        return (state.isEmpty ? "" : state.joined(separator: ", ") + ". ") + detail
    }
}

// MARK: - Auswahlliste (`InstrumentList`, `InstrumentListRow`)

struct DraftListItem: Identifiable, Hashable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    var badges: [DraftBadge] = []
    var status: StatusItem?
    var finding = false
}

struct DraftListSection: Identifiable, Hashable {
    let id: String
    let title: String
    var finding = false
    var tone = StatusTone.neutral
    let items: [DraftListItem]
}

/// Zeile der Auswahlliste: gewählt mit Fläche und Fokusleiste im Grantry-Verlauf statt der Systemakzentfarbe; für
/// VoiceOver ein Element „Name“ mit Wert „Zustand. Detail“, Taste und `isSelected`.
struct DraftListRow: View {
    let item: DraftListItem
    let isSelected: Bool

    var body: some View {
        let head = DraftRowHead(symbol: item.symbol, title: item.title, detail: item.detail, badges: item.badges,
                                status: item.status, finding: item.finding)
        head
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.item)
            .instrumentRowBackground(isSelected: isSelected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: item.title))
            .accessibilityValue(Text(verbatim: head.spokenValue))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Auswahlliste im Panel: Kopf mit Titel und Anzahl, Gruppenköpfe wie in gruppierten Tabellen, Zeilen. In LB-1.2 lazy,
/// mit Pfeiltasten, Return und Kontextmenü.
struct DraftList: View {
    let title: String
    let count: String
    let sections: [DraftListSection]
    let selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: InstrumentSpacing.item) {
                Text(verbatim: title).font(InstrumentFont.title).accessibilityAddTraits(.isHeader)
                Spacer(minLength: InstrumentSpacing.group)
                Text(verbatim: count).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
            }
            .padding(.horizontal, InstrumentSpacing.panel)
            .padding(.vertical, InstrumentSpacing.cell)
            Divider()
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                ForEach(sections) { section in
                    InstrumentSectionHeader(title: section.title, count: section.items.count, tone: section.tone,
                                            finding: section.finding)
                    ForEach(section.items) { item in
                        DraftListRow(item: item, isSelected: item.id == selection)
                    }
                }
            }
            .padding(InstrumentSpacing.item)
            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
        .instrumentPanel(padding: 0)
    }
}

// MARK: - Detail-Panel (`DetailPanel`, `DetailGroup`, `DetailEntry`)

/// Kopf des Details: großes Symbol im Kreis, Titel als Überschrift, Kennung in Festbreitenschrift, rechts Zustandschips.
struct DraftDetailHead: View {
    let symbol: String
    let title: String
    let subtitle: String
    var items: [StatusItem] = []
    var finding = false

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            DraftRowIcon(symbol: symbol, finding: finding, size: InstrumentSize.shield)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.verdict).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle).font(InstrumentFont.code).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
            Spacer(minLength: InstrumentSpacing.group)
            ForEach(items, id: \.self) { StatusChip($0) }
        }
    }
}

/// Gruppe im Detail: Überschrift mit Anzahl, darunter die Einträge.
struct DraftDetailGroup<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            HStack(spacing: InstrumentSpacing.item) {
                Text(verbatim: title).font(InstrumentFont.title)
                if let count {
                    Text(verbatim: "\(count)").font(InstrumentFont.label.monospacedDigit())
                        .foregroundStyle(.instrumentSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Schlüssel-Wert-Zeile im Detail: Schlüssel links in fester Breite und Sekundärfarbe, Wert rechts, auf Wunsch mit Ton
/// oder in Festbreitenschrift. VoiceOver liest „Schlüssel“ mit dem Wert, nicht nur den Titel (#563).
struct DraftDetailEntry: View {
    let key: String
    let value: String
    var tone: StatusTone?
    var isCode = false

    @Environment(\.self) private var environment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.cell) {
            Text(verbatim: key).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                .frame(width: InstrumentSize.laneLabel, alignment: .leading)
            Text(verbatim: value)
                .font(isCode ? InstrumentFont.code : InstrumentFont.body)
                .foregroundStyle(tone.map(environment.statusTextColor) ?? .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: key))
        .accessibilityValue(Text(verbatim: value))
    }
}

/// Eintrag mit Aktionen im Detail (etwa eine Berechtigung): Zeilenkopf, Hinweise und native Knöpfe darunter, auf der
/// Mulde abgesetzt; läuft eine Aktion, steht ein Fortschritt mit Text daneben.
struct DraftDetailItem<Notes: View, Actions: View>: View {
    let head: DraftRowHead
    var isRunning = false
    @ViewBuilder let notes: Notes
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            head
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: head.title))
                .accessibilityValue(Text(verbatim: head.spokenValue))
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                notes
                HStack(spacing: InstrumentSpacing.group) {
                    actions
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Text("Wird zurückgesetzt …").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    }
                }
                .controlSize(.small)
            }
            .padding(.leading, InstrumentSize.rowIconTall + InstrumentSpacing.cell)
        }
        .padding(InstrumentSpacing.group)
        .background(RoundedRectangle(cornerRadius: InstrumentRadius.block, style: .continuous)
            .fill(.primary.opacity(InstrumentOpacity.well)))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Hinweiszeile (`InstrumentNote`)

/// Hinweis im Inhalt (§ 3.12): `info` und `locked` klein in Sekundärfarbe, Befund mit Befund-Punkt, Fehler mit Symbol in
/// `critical`; zusammengeführt aus `NetworkNote`, ersetzt `NoticeList`, `InfoLabel`, `RecordHints` und `HintLabel`.
struct DraftNote: View {
    enum Kind {
        case info, locked, finding, critical

        var spoken: String {
            switch self {
            case .info: "Hinweis"
            case .locked: "gesperrt"
            case .finding: "auffällig"
            case .critical: "Fehler"
            }
        }
    }

    let text: String
    var kind = Kind.info

    @Environment(\.self) private var environment

    var body: some View {
        let quiet = kind == .info || kind == .locked
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.item) {
            switch kind {
            case .info, .locked:
                Image(systemName: kind == .info ? "info.circle" : "lock").foregroundStyle(.instrumentSecondary)
            case .finding:
                FindingDot(size: InstrumentSize.findingDotSmall)
            case .critical:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(environment.statusColor(.critical))
            }
            Text(verbatim: text)
                .foregroundStyle(quiet ? AnyShapeStyle(.instrumentSecondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(quiet ? InstrumentFont.label : InstrumentFont.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: kind.spoken))
        .accessibilityValue(Text(verbatim: text))
    }
}

// MARK: - Banner (`InstrumentBanner`)

/// Hinweis oben im Bereich: Leiste im Zustandston (Befund mit Befund-Punkt), Titel und ein Satz, rechts native Knöpfe.
/// Ersetzt `PrerequisitesBanner`, `DashboardBanner`, `UpdateBanner` und `ActionResultBanner`.
struct DraftBanner<Actions: View>: View {
    let title: String
    let message: String
    let tone: StatusTone
    @ViewBuilder let actions: Actions

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            Capsule().fill(environment.statusColor(tone))
                .frame(width: InstrumentStroke.focusBar)
                .overlay(alignment: .top) {
                    if tone == .finding { FindingDot(size: InstrumentSize.findingDotSmall) }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold))
                Text(verbatim: message).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(Text(verbatim: message))
            Spacer(minLength: InstrumentSpacing.group)
            HStack(spacing: InstrumentSpacing.group) { actions }
                .controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, InstrumentSpacing.panel)
        .padding(.vertical, InstrumentSpacing.cell)
        .instrumentPanel(padding: 0)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Häkchenzeile (`SelectionCheckRow`)

/// Häkchen im Grantry-Verlauf statt der Systemakzentfarbe; leer mit Rand in Sekundärfarbe (≥ 3 : 1).
struct DraftCheckBox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(GrantryBrand.fill)
                Image(systemName: "checkmark").font(InstrumentFont.micro.weight(.bold)).foregroundStyle(.white)
            } else {
                shape.strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.focus)
            }
        }
        .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
        .accessibilityHidden(true)
    }
}

/// Zeile zum Ankreuzen: Häkchen, Name und Detail, Hinweis als Chip, rechts die Größe; gesperrt mit Schloss und Grund.
/// Für VoiceOver ein Schalter „Name“ mit Wert „ausgewählt, Größe“; gesperrt nennt er den Grund. Der Zustand kommt nur
/// gebunden herein, die Vorauswahl bleibt Sache des Modells.
struct DraftCheckRow: View {
    let title: String
    let detail: String
    let size: String
    let isOn: Bool
    var hint: StatusItem?
    var lockedReason: String?

    var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            if lockedReason != nil {
                Image(systemName: "lock").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
            } else {
                DraftCheckBox(isOn: isOn)
            }
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body).lineLimit(1)
                Text(verbatim: lockedReason ?? detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: InstrumentSpacing.group)
            if let hint { StatusChip(hint, isSmall: true) }
            Text(verbatim: size).font(InstrumentFont.numeric).foregroundStyle(.instrumentSecondary)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: spokenValue))
        .accessibilityAddTraits(lockedReason == nil ? .isToggle : [])
    }

    private var spokenValue: String {
        if let lockedReason { return "gesperrt: \(lockedReason). \(size)" }
        let state = isOn ? "ausgewählt" : "nicht ausgewählt"
        return [state, hint?.text, size, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Fortschritt und Abdeckung als Spur

/// Scan-Fortschritt oder Abdeckung als Spur mit Text darüber; `fraction == nil` heißt „Dauer noch unbekannt“ (leere
/// Bahn, kein Lauflicht). Ersetzt `ScanProgressView`, `SegmentScanProgress` und die Leiste von `AreaCoverageBar`.
struct DraftProgressSpur<Trailing: View>: View {
    let title: String
    let detail: String
    let fraction: Double?
    let tone: StatusTone
    @ViewBuilder let trailing: Trailing

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold))
                Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
                Spacer(minLength: InstrumentSpacing.group)
                trailing
            }
            Spur(fraction: fraction, color: environment.statusColor(tone))
                .frame(height: InstrumentSize.spurList)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: spokenValue))
    }

    private var spokenValue: String {
        let share = fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        return [share, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

extension DraftProgressSpur where Trailing == EmptyView {
    init(title: String, detail: String, fraction: Double?, tone: StatusTone) {
        self.init(title: title, detail: detail, fraction: fraction, tone: tone) { EmptyView() }
    }
}

// MARK: - Leerzustand im Panel

/// Leerzustand im Panel (§ 3.11): Symbol, Titel und ein Satz, mittig.
struct DraftEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(verbatim: message).foregroundStyle(.instrumentSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
