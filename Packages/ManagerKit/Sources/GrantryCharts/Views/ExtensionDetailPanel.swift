import SwiftUI

/// Detail der gewählten Erweiterung unter der Tabelle: Kopf mit Zustand und Bewertung; links was die Art darf und die
/// Befunde mit der eigenen Einschätzung, rechts die Herkunft samt Pfad; unten die Aktionen. `acceptance` (Knopf „Risiko
/// akzeptieren“ bzw. „Akzeptanz aufheben“) und `actions` liefert die Ansicht der App.
public struct ExtensionDetailPanel<Acceptance: View, Actions: View>: View {
    let content: ExtensionDetailContent
    let acceptance: Acceptance
    let actions: Actions

    public init(content: ExtensionDetailContent, @ViewBuilder acceptance: () -> Acceptance,
                @ViewBuilder actions: () -> Actions) {
        self.content = content
        self.acceptance = acceptance()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            ExtensionDetailHeader(symbol: content.symbol, title: content.title, subtitle: content.subtitle,
                                  state: content.state, rating: content.rating)
            Divider()
            HStack(alignment: .top, spacing: InstrumentSpacing.empty) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    ExtensionDetailGroup(title: String(localized: "Was sie darf")) {
                        Text(verbatim: content.permission).font(InstrumentFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ExtensionFindingsGroup(findings: content.findings, acceptanceText: content.acceptance) {
                        acceptance
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ExtensionDetailGroup(title: String(localized: "Herkunft")) {
                    ExtensionFactGrid(facts: content.facts)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: InstrumentSpacing.group) {
                actions.font(InstrumentFont.body)
                Spacer(minLength: 0)
            }
        }
        .instrumentPanel()
    }
}

/// Kopf des Details: Symbol der Art, Name, Art und Herkunft; rechts Zustand und Bewertung.
private struct ExtensionDetailHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    let state: StatusItem
    let rating: StatusItem?

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            ExtensionSymbol(symbol: symbol, size: InstrumentSize.shield)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title)
                    .font(InstrumentFont.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: subtitle).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
            Spacer(minLength: InstrumentSpacing.group)
            StatusChip(state)
            if let rating { StatusChip(rating) }
        }
    }
}

/// Gruppe im Detail: Überschrift, darunter der Inhalt.
private struct ExtensionDetailGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            Text(verbatim: title).font(InstrumentFont.title).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// Befunde mit Punkt im Ton und Satz; darunter die eigene Einschätzung mit dem Knopf der Ansicht.
private struct ExtensionFindingsGroup<Acceptance: View>: View {
    let findings: [StatusItem]
    let acceptanceText: String?
    @ViewBuilder let acceptance: Acceptance

    @Environment(\.self) private var environment

    var body: some View {
        ExtensionDetailGroup(title: String(localized: "Befunde")) {
            if findings.isEmpty {
                Text("Grantry fällt an dieser Erweiterung nichts auf.")
                    .font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
            ForEach(findings, id: \.self) { finding in
                HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.item) {
                    Group {
                        if finding.tone == .finding {
                            FindingDot(size: InstrumentSize.findingDotSmall)
                        } else {
                            Circle().fill(environment.statusColor(finding.tone))
                                .frame(width: InstrumentSize.statusDot, height: InstrumentSize.statusDot)
                        }
                    }
                    .frame(width: InstrumentSize.findingDot)
                    .accessibilityHidden(true)
                    Text(verbatim: finding.text).font(InstrumentFont.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let acceptanceText {
                Text(verbatim: acceptanceText).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                acceptance.font(InstrumentFont.body)
            }
        }
    }
}

/// Herkunft als Zeilen: Titel links in der Sekundärfarbe, Wert rechts daneben; Kennungen in Festbreitenschrift. VoiceOver
/// liest je Zeile ein Element mit Titel und Wert; `GridRow` fasst nicht zusammen, der auswählbare Wert stand sonst als
/// AXUnknown ohne Titel da (#563).
private struct ExtensionFactGrid: View {
    let facts: [ExtensionDetailContent.Fact]

    @Environment(\.self) private var environment

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: InstrumentSpacing.panel,
             verticalSpacing: InstrumentSpacing.item) {
            ForEach(facts, id: \.self) { fact in
                GridRow {
                    Text(verbatim: fact.title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    Text(verbatim: fact.value)
                        .font(fact.isCode ? InstrumentFont.code : InstrumentFont.body)
                        .foregroundStyle(fact.tone.flatMap {
                            $0 == .neutral ? nil : AnyShapeStyle(environment.statusTextColor($0))
                        } ?? AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityReading(Text(verbatim: fact.title), value: Text(verbatim: fact.value))
                }
            }
        }
    }
}

/// Detail, solange keine Erweiterung gewählt ist (§3.11).
public struct ExtensionNoSelection: View {
    public init() {}

    public var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Wähle eine Erweiterung, um zu sehen, was sie darf, woher sie kommt und was Grantry auffällt.")
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity)
        .instrumentPanel(padding: 0)
    }
}
