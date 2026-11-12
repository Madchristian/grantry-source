import SwiftUI

// Knopfzeile und Sprungzeile der Liste-Detail-Ansichten (LB-2.2, #539; Entwurf LB-2.1, #538, Spec 2026-11-10 §11.2 d
// und e): Aktionen des gewählten Eintrags direkt unter dem Detailkopf, Verknüpfungen in andere Bereiche als Zeile mit
// Pfeil. Knöpfe bleiben native Steuerelemente.

/// Knopfzeile unter dem Detailkopf ohne eigene Gruppe (§11.2 d): native Knöpfe nebeneinander; läuft eine Aktion, steht
/// daneben ein Fortschritt mit ihrem Text. Gesperrte Aktionen nennen ihren Grund als `InstrumentNote` darunter.
public struct DetailActions<Actions: View>: View {
    let runningText: String?
    let actions: Actions

    public init(runningText: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.runningText = runningText
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            actions
            if let runningText { RunningActionLabel(runningText) }
        }
    }
}

/// Laufende Aktion: kleiner Fortschritt und Text in `font.label` sekundär. VoiceOver liest „läuft“ mit dem Text als Wert.
public struct RunningActionLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            ProgressView().controlSize(.small)
            Text(verbatim: text).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
        }
        .accessibilityReading(Text(verbatim: String(localized: "läuft")), value: Text(verbatim: text))
    }
}

/// Sprungzeile im Detail (§11.2 e), etwa eine Berechtigung einer App: Zeilenkopf mit Zustand und Pfeil; ein Klick zeigt
/// den Eintrag im Bereich `destination`. Für VoiceOver ein Knopf mit Name, Zustand und dem Ziel als Hinweis.
public struct JumpRow<Icon: View>: View {
    let content: InstrumentRowContent
    let destination: String
    let action: () -> Void
    let icon: Icon

    public init(_ content: InstrumentRowContent, destination: String, action: @escaping () -> Void,
                @ViewBuilder icon: () -> Icon) {
        self.content = content
        self.destination = destination
        self.action = action
        self.icon = icon()
    }

    /// Hinweis für VoiceOver: wohin der Sprung führt.
    static func spokenHint(destination: String) -> String {
        String(localized: "Zeigt den Eintrag im Bereich „\(destination)“.")
    }

    /// Tooltip der Zeile.
    static func helpText(destination: String) -> String {
        String(localized: "In „\(destination)“ zeigen")
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: InstrumentSpacing.cell) {
                InstrumentRowLabel(content) { icon }
                Image(systemName: "chevron.right").font(InstrumentFont.micro.weight(.semibold))
                    .foregroundStyle(.instrumentSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.item)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .instrumentRowBackground(isSelected: false)
        .help(Text(verbatim: Self.helpText(destination: destination)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: content.title))
        // ax-value: Knopf behält Rolle und Wert (AXButton mit Name und Zustand, DetailAccessibilityTests).
        .accessibilityValue(Text(verbatim: content.spokenValue))
        .accessibilityHint(Text(verbatim: Self.spokenHint(destination: destination)))
        .accessibilityAddTraits(.isButton)
    }
}

extension JumpRow where Icon == InstrumentRowIcon {
    public init(_ content: InstrumentRowContent, destination: String, action: @escaping () -> Void) {
        self.init(content, destination: destination, action: action) { InstrumentRowIcon(symbol: content.symbol) }
    }
}
