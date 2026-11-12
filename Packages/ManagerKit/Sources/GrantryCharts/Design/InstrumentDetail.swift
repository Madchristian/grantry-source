import SwiftUI

// Detail im Lagebild (LB-1.2, #536; Spec 2026-11-10 §4.2, Entscheidung 2): Panel mit Kopf, Gruppen mit Überschrift und
// Schlüssel-Wert-Zeilen statt `Form`, `Section` und `LabeledContent`; zusammengeführt aus den Netzwerk-Bausteinen.
// Schlüssel links, Wert rechts (Spec §11.1 a); Einträge mit Aktionen auf der Mulde (§11.1 c). Knöpfe und Schalter darin
// bleiben native Steuerelemente.

/// Detail-Panel: Inhalt untereinander im Abstand `space.bar`, rollt im Panel, wenn er nicht passt.
public struct DetailPanel<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ChartScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
                content
            }
            .padding(InstrumentSpacing.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel(padding: 0)
    }
}

/// Kopf des Details: großes Symbol im Kreis (oder ein eigenes wie das App-Symbol) mit Befund-Punkt, Titel als Überschrift,
/// darunter die Kennung in Festbreitenschrift, rechts Zustandschips.
public struct DetailHead<Icon: View>: View {
    let title: String
    let subtitle: String
    let items: [StatusItem]
    let finding: Bool
    let icon: Icon

    public init(title: String, subtitle: String, items: [StatusItem] = [], finding: Bool = false,
                @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.finding = finding
        self.icon = icon()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            icon.instrumentFindingDot(finding)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.verdict).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle).font(InstrumentFont.code).foregroundStyle(.instrumentSecondary).lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: InstrumentSpacing.group)
            ForEach(items, id: \.self) { StatusChip($0) }
        }
    }
}

extension DetailHead where Icon == InstrumentRowIcon {
    public init(symbol: String, title: String, subtitle: String, items: [StatusItem] = [], finding: Bool = false) {
        self.init(title: title, subtitle: subtitle, items: items, finding: finding) {
            InstrumentRowIcon(symbol: symbol, size: InstrumentSize.shield)
        }
    }
}

/// Gruppe im Detail: Überschrift (für VoiceOver eine Überschrift) mit Anzahl, darunter die Einträge.
public struct DetailGroup<Content: View>: View {
    let title: String
    let count: Int?
    let content: Content

    public init(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.content = content()
    }

    public var body: some View {
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

/// Schlüssel-Wert-Zeile im Detail: Schlüssel links in fester Breite und Sekundärfarbe, Wert rechts. Als Text mit Ton oder
/// in Festbreitenschrift, auswählbar; oder eigener Inhalt (Link, Signatur, Datum). VoiceOver liest den Schlüssel mit dem
/// Wert, nie nur den Titel (#563): Zusammengefasst (`children: .combine`) ging unter macOS 27 auswählbarer Text verloren,
/// das Feld „Art“ im Detail eines Sockets meldete sich als AXUnknown nur mit „Art“ (Abnahme 2026.11.10/1572).
public struct DetailEntry<Content: View>: View {
    let key: String
    /// Wert für VoiceOver; ohne ihn (nur bei einem Bedienelement) liest VoiceOver Schlüssel und Element zusammen.
    let spokenValue: String?
    let content: Content

    /// Eigener Inhalt wie Signatur, Pfad oder App; `value` ist, was VoiceOver nach dem Schlüssel liest.
    public init(_ key: String, value: String, @ViewBuilder content: () -> Content) {
        self.key = key
        self.spokenValue = value
        self.content = content()
    }

    /// Bedienelement wie ein Link: Es bleibt ein Knopf, VoiceOver liest den Schlüssel vor seiner Beschriftung.
    public init(_ key: String, @ViewBuilder control: () -> Content) {
        self.key = key
        self.spokenValue = nil
        self.content = control()
    }

    public var body: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.cell) {
            Text(verbatim: key).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: InstrumentSize.laneLabel, alignment: .leading)
            content
                .font(InstrumentFont.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let spokenValue {
            row.accessibilityReading(Text(verbatim: key), value: Text(verbatim: spokenValue))
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}

/// Wert einer Schlüssel-Wert-Zeile als Text: mit Ton in dessen Textfarbe (neutral wie ohne Ton), auf Wunsch in
/// Festbreitenschrift für Pfade, Adressen und Kennungen; auswählbar, lange Werte in der Mitte gekürzt.
public struct DetailValueText: View {
    let value: String
    let tone: StatusTone?
    let isCode: Bool

    @Environment(\.self) private var environment

    public var body: some View {
        Text(verbatim: value)
            .font(isCode ? InstrumentFont.code : InstrumentFont.body)
            .foregroundStyle(tone.flatMap { $0 == .neutral ? nil : AnyShapeStyle(environment.statusTextColor($0)) }
                ?? AnyShapeStyle(.primary))
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
    }
}

extension DetailEntry where Content == DetailValueText {
    public init(_ key: String, value: String, tone: StatusTone? = nil, isCode: Bool = false) {
        self.key = key
        self.spokenValue = value
        self.content = DetailValueText(value: value, tone: tone, isCode: isCode)
    }
}

/// Eintrag mit Aktionen im Detail (etwa eine Berechtigung): Zeilenkopf, darunter Hinweise und native Knöpfe, auf der Mulde
/// abgesetzt (Spec §11.1 c). Läuft eine Aktion, steht `runningText` mit Fortschritt neben den Knöpfen.
public struct DetailItem<Icon: View, Notes: View, Actions: View>: View {
    let content: InstrumentRowContent
    let runningText: String?
    let icon: Icon
    let notes: Notes
    let actions: Actions

    public init(_ content: InstrumentRowContent, runningText: String? = nil, @ViewBuilder icon: () -> Icon,
                @ViewBuilder notes: () -> Notes, @ViewBuilder actions: () -> Actions) {
        self.content = content
        self.runningText = runningText
        self.icon = icon()
        self.notes = notes()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            InstrumentRowLabel(content) { icon }
                .accessibilityReading(Text(verbatim: content.title), value: Text(verbatim: content.spokenValue))
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                notes
                DetailActions(runningText: runningText) { actions }
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

extension DetailItem where Icon == InstrumentRowIcon {
    public init(_ content: InstrumentRowContent, runningText: String? = nil, @ViewBuilder notes: () -> Notes,
                @ViewBuilder actions: () -> Actions) {
        self.init(content, runningText: runningText, icon: { InstrumentRowIcon(symbol: content.symbol) },
                  notes: notes, actions: actions)
    }
}
