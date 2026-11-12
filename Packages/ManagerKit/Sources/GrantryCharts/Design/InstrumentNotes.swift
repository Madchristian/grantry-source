import SwiftUI

// Hinweise im Lagebild (LB-1.2, #536; Standard §3.11, §3.12): Hinweiszeile im Inhalt, Banner oben im Bereich und
// Leerzustand im Panel. Farben nur aus `StatusTone`, Befund mit dem Befund-Punkt.

/// Hinweis im Inhalt (§3.12): `info` und `locked` klein in Sekundärfarbe, ein Befund mit Befund-Punkt, ein Fehler mit
/// Symbol in `critical`, beide mit Text in `font.body`. Zusammengeführt aus `NetworkNote`; ersetzt `NoticeList`,
/// `InfoLabel`, `RecordHints` und `HintLabel`. VoiceOver liest die Art als Beschriftung, den Text als Wert.
public struct InstrumentNote: View {
    public enum Kind: Sendable {
        case info, locked, finding, critical

        /// Beschriftung für VoiceOver.
        public var spoken: String {
            switch self {
            case .info: String(localized: "Hinweis")
            case .locked: String(localized: "gesperrt")
            case .finding: String(localized: "auffällig")
            case .critical: String(localized: "Fehler")
            }
        }

        var isQuiet: Bool { self == .info || self == .locked }
    }

    let text: String
    let kind: Kind

    @Environment(\.self) private var environment

    public init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.item) {
            switch kind {
            case .info, .locked:
                Image(systemName: kind == .info ? "info.circle" : "lock").foregroundStyle(.instrumentSecondary)
            case .finding:
                FindingDot(size: InstrumentSize.findingDotSmall)
            case .critical:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(environment.statusColor(.critical))
            }
            // Ohne `fixedSize(vertical:)` wie im Banner (d342e9b): Hinweise stehen auch über Listen im Fensterrahmen.
            Text(verbatim: text)
                .foregroundStyle(kind.isQuiet ? AnyShapeStyle(.instrumentSecondary) : AnyShapeStyle(.primary))
        }
        .font(kind.isQuiet ? InstrumentFont.label : InstrumentFont.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityReading(Text(verbatim: kind.spoken), value: Text(verbatim: text))
    }
}

/// Hinweis oben im Bereich (Voraussetzung fehlt, Update, Ergebnis einer Aktion, Fehler): Leiste im Zustandston (beim
/// Befund mit Befund-Punkt), Titel und ein Satz, rechts native Knöpfe. Ersetzt `PrerequisitesBanner`, `DashboardBanner`,
/// `UpdateBanner` und `ActionResultBanner`. VoiceOver liest den Titel als Beschriftung, den Satz als Wert.
public struct InstrumentBanner<Actions: View>: View {
    let title: String
    let message: String
    let tone: StatusTone
    let actions: Actions

    @Environment(\.self) private var environment

    public init(_ title: String, message: String, tone: StatusTone, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.tone = tone
        self.actions = actions()
    }

    public var body: some View {
        // Ohne `fixedSize(vertical:)` (d342e9b): Bei der Mindestgrößen-Abfrage des Fensters (Breite 0) meldete der Text
        // sonst über 1000 pt Höhe und schob den Fensterinhalt unter die Titelleiste; umbrechen tut er auch so. Die Leiste
        // liegt deshalb als Overlay auf dem Inhalt und nimmt dessen Höhe, statt als Form im Stapel Höhe zu beanspruchen.
        HStack(spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(.semibold))
                if !message.isEmpty {
                    Text(verbatim: message).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                }
            }
            .accessibilityReading(Text(verbatim: title), value: Text(verbatim: message))
            Spacer(minLength: InstrumentSpacing.group)
            HStack(spacing: InstrumentSpacing.group) { actions }
                .controlSize(.small)
        }
        .padding(.leading, InstrumentStroke.focusBar + InstrumentSpacing.panel)
        .overlay(alignment: .leading) {
            Capsule().fill(environment.statusColor(tone))
                .frame(width: InstrumentStroke.focusBar)
                .overlay(alignment: .top) {
                    if tone == .finding { FindingDot(size: InstrumentSize.findingDotSmall) }
                }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, InstrumentSpacing.panel)
        .padding(.vertical, InstrumentSpacing.cell)
        .instrumentPanel(padding: 0)
        .accessibilityElement(children: .contain)
    }
}

extension InstrumentBanner where Actions == EmptyView {
    public init(_ title: String, message: String, tone: StatusTone) {
        self.init(title, message: message, tone: tone) { EmptyView() }
    }
}

/// „Meldung schließen“ rechts in einem `InstrumentBanner` (LB-5.5, #556): nur das Symbol, ohne Rahmen, Tooltip und
/// VoiceOver nennen den Titel. Ein Baustein für Ergebnis-Meldungen der App und die Galerie.
public struct BannerDismissButton: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(String(localized: "Meldung schließen"), systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(Text(verbatim: String(localized: "Meldung schließen")))
    }
}

/// Leerzustand (§3.11, Spec §11.1 e): Symbol, Titel und ein Satz mittig im Panel, das sonst den Inhalt zeigt – noch kein
/// Scan, keine Treffer, nichts gewählt. Das Panel setzt der Aufrufer (`instrumentPanel()`).
public struct InstrumentEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    public init(symbol: String, title: String, message: String) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
        } description: {
            Text(verbatim: message).foregroundStyle(.instrumentSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
