import SwiftUI

// Fenster außerhalb der Bereiche im Lagebild (LB-5.2, #553; Entwurf LB-5.1, #552, Spec 2026-11-10 § 11.5): Gruppe der
// Einstellungen als Panel, Einstellung mit Erklärung und nativem Steuerelement (Entscheidung 3) und die Aktionsleiste
// unten im Fenster. Zuerst in den Einstellungen; Onboarding, Was ist neu und das Menüleisten-Menü (#554, #555) nutzen
// dieselben Bausteine.

/// Panel mit Peilkopf ohne Ring (Standard § 3.3: keine Messgröße) und Inhalt darunter: Gruppe der Einstellungen, Panels
/// des Menüleisten-Menüs, Höhepunkte in „Was ist neu“. Rechts im Kopf auf Wunsch ein nativer Knopf (etwa „Erneut
/// prüfen“). VoiceOver: Titel als Überschrift, das Panel als Gruppe mit dem Titel.
public struct SettingsPanel<Accessory: View, Content: View>: View {
    let title: String
    let detail: String
    let value: String
    let finding: Bool
    let accessory: Accessory
    let content: Content

    public init(_ title: String, detail: String = "", value: String = "", finding: Bool = false,
                @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.value = value
        self.finding = finding
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            HStack(spacing: InstrumentSpacing.group) {
                PeilHead(title, detail: detail, value: value, finding: finding)
                accessory.controlSize(.small)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }
}

extension SettingsPanel where Accessory == EmptyView {
    public init(_ title: String, detail: String = "", value: String = "", finding: Bool = false,
                @ViewBuilder content: () -> Content) {
        self.init(title, detail: detail, value: value, finding: finding, accessory: { EmptyView() }, content: content)
    }
}

/// Eine Einstellung: Titel in `font.body` und Erklärung in `font.label` sekundär links, rechts das native Steuerelement.
/// Mit `labelsControl` liest VoiceOver nur das Steuerelement, mit dem Titel als Beschriftung und der Erklärung als
/// Hinweis; sonst (mehrere Steuerelemente oder ein Knopf mit eigener Beschriftung) liest es den Titel mit der Erklärung
/// als Wert und daneben die Steuerelemente mit ihren eigenen Beschriftungen.
public struct SettingRow<Control: View>: View {
    let title: String
    let note: String?
    let labelsControl: Bool
    let control: Control

    public init(_ title: String, note: String? = nil, labelsControl: Bool = true,
                @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.labelsControl = labelsControl
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(verbatim: note).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityReading(Text(verbatim: title), value: Text(verbatim: note ?? ""))
            .accessibilityHidden(labelsControl)
            Spacer(minLength: InstrumentSpacing.group)
            if labelsControl {
                control
                    .accessibilityLabel(Text(verbatim: title))
                    .accessibilityHint(Text(verbatim: note ?? ""))
            } else {
                control
            }
        }
    }
}

/// Einstellung mit nativem Schalter (Spec § 11.5 b: alle Einstellungen als Schalter). Gesperrt über `.disabled(_:)`;
/// die Erklärung nennt dann den Grund. `identifier` ist die Kennung der UI-Tests. Mit `chartDrawsSwitches` (Bild-Tests)
/// statt des AppKit-Schalters ein gezeichneter (`SnapshotSwitch`).
public struct SettingToggle: View {
    let title: String
    let note: String?
    @Binding var isOn: Bool
    let identifier: String?

    @Environment(\.chartDrawsSwitches) private var drawsSwitch

    public init(_ title: String, note: String? = nil, isOn: Binding<Bool>, identifier: String? = nil) {
        self.title = title
        self.note = note
        _isOn = isOn
        self.identifier = identifier
    }

    public var body: some View {
        SettingRow(title, note: note) {
            if drawsSwitch {
                SnapshotSwitch(isOn: isOn)
            } else {
                Toggle(isOn: $isOn) { Text(verbatim: title) }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier(identifier ?? title)
            }
        }
    }
}

/// Gezeichneter kleiner Schalter für Bilder: Spur und Knopf in Primärfarbe statt Akzentfarbe, damit das Bild nicht von
/// den Systemeinstellungen abhängt; gesperrt blass. Steht auf der Textzeile des Titels, damit die Zeile wie mit dem
/// nativen Schalter an der ersten Grundlinie ausgerichtet bleibt.
private struct SnapshotSwitch: View {
    let isOn: Bool

    @Environment(\.isEnabled) private var isEnabled

    private static let size = CGSize(width: 26, height: 15)
    private static let inset: CGFloat = 1.5

    var body: some View {
        Text(verbatim: " ").font(InstrumentFont.body)
            .frame(width: Self.size.width)
            .hidden()
            .overlay {
                Capsule()
                    .fill(.primary.opacity(isOn ? InstrumentOpacity.blockBorder : InstrumentOpacity.track))
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(.white).padding(Self.inset)
                    }
                    .frame(width: Self.size.width, height: Self.size.height)
                    .opacity(isEnabled ? 1 : InstrumentOpacity.blockBorder)
            }
            .accessibilityHidden(true)
    }
}

/// Zeile am Ende einer Gruppe mit Stand und nativen Knöpfen, etwa „Zuletzt geprüft …“ und „Jetzt prüfen“: links der
/// Stand in `font.label` sekundär, rechts eine laufende Aktion mit Text (`RunningActionLabel`) und die Knöpfe.
public struct SettingActionLine<Actions: View>: View {
    let text: String
    let runningText: String?
    let actions: Actions

    public init(_ text: String, runningText: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.runningText = runningText
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            Text(verbatim: text).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            Spacer(minLength: InstrumentSpacing.group)
            if let runningText { RunningActionLabel(runningText) }
            actions.controlSize(.small)
        }
    }
}

/// Aktionsleiste unten im Fenster oder Blatt (Standard § 3.1, `instrumentBar()`): links ein Satz oder Link, rechts die
/// nativen Knöpfe.
public struct WindowBar<Leading: View, Actions: View>: View {
    let leading: Leading
    let actions: Actions

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.leading = leading()
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            leading
            Spacer(minLength: InstrumentSpacing.group)
            actions
        }
        .frame(maxWidth: .infinity)
        .instrumentBar()
    }
}

/// Inhalt eines Fensters oder Blatts außerhalb der Bereiche (LB-5.3, #554: Onboarding, Was ist neu): Panels mit
/// Seitenrand auf dem Grund, unten die Aktionsleiste (`WindowBar`); feste Breite, Höhe nach dem Inhalt.
public struct WindowContent<Content: View, Bar: View>: View {
    let width: CGFloat
    let content: Content
    let bar: Bar

    public init(width: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.width = width
        self.content = content()
        self.bar = bar()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) { content }
                .padding(InstrumentSpacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            bar
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .instrumentBackground()
    }
}

/// Höhepunkt in „Was ist neu“ (LB-5.3, #554; Spec § 11.5 h): Symbol im Kreis (`InstrumentRowIcon`), Titel semibold,
/// Text in `font.label` sekundär und umbrechend. VoiceOver liest den Titel als Beschriftung und den Text als Wert.
public struct HighlightRow: View {
    let symbol: String
    let title: String
    let text: String

    public init(symbol: String, title: String, text: String) {
        self.symbol = symbol
        self.title = title
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.cell) {
            InstrumentRowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold))
                Text(verbatim: text).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityReading(Text(verbatim: title), value: Text(verbatim: text))
    }
}
