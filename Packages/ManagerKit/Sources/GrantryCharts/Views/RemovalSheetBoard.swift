import SwiftUI

// Blatt „App entfernen“ im Lagebild (LB-4.5, #551; Entwurf LB-4.1, #547, Spec 2026-11-10 § 11.4 f): Peilkopf mit
// App-Symbol ohne Ring, Titel und Ort in Code-Schrift, Hinweise unter dem Kopf, darunter das Fund-Panel mit der
// Aktionsleiste unten. Auswahl, Suche, Homebrew-Hinweis und Fortschritt der Selbstdeinstallation liefern die Slots.

/// Maße des Blatts „App entfernen“: Breite wie bisher und Höhe des Panels.
public enum RemovalSheetLayout {
    /// Breite des Blatts.
    public static let width: CGFloat = 600
    static let scrollingMinHeight: CGFloat = 220
    static let scrollingIdealHeight: CGFloat = 380
    static let fittingMinHeight: CGFloat = 160

    /// Höhe des Panels: `scrolling` mit Mindest- und Wunschhöhe für eine rollende Fundliste, `fitting` nach Inhalt.
    public enum Panel: Sendable {
        case scrolling, fitting
    }
}

/// Rahmen des Blatts „App entfernen“: Kopf, Hinweise (`notes`), Panel mit Inhalt und Leiste (`InstrumentActionBar`).
/// Mit `.scrolling` hat das Panel eine Mindest- und Wunschhöhe, damit eine rollende Fundliste (`CleanupFindingList`) im
/// Blatt Platz bekommt; mit `.fitting` nimmt es die Höhe seines Inhalts.
public struct RemovalSheetBoard<Icon: View, Notes: View, Content: View, Bar: View>: View {
    let title: String
    let path: String
    let panel: RemovalSheetLayout.Panel
    let icon: Icon
    let notes: Notes
    let content: Content
    let bar: Bar

    public init(title: String, path: String, panel: RemovalSheetLayout.Panel = .fitting, @ViewBuilder icon: () -> Icon,
                @ViewBuilder notes: () -> Notes, @ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.title = title
        self.path = path
        self.panel = panel
        self.icon = icon()
        self.notes = notes()
        self.content = content()
        self.bar = bar()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            DetailHead(title: title, subtitle: path) { icon }
            notes
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                bar
            }
            .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
            .instrumentPanel(padding: 0)
            .frame(minHeight: panel == .scrolling ? RemovalSheetLayout.scrollingMinHeight
                       : RemovalSheetLayout.fittingMinHeight,
                   idealHeight: panel == .scrolling ? RemovalSheetLayout.scrollingIdealHeight : nil)
        }
        .padding(InstrumentSpacing.page)
        .frame(width: RemovalSheetLayout.width, alignment: .topLeading)
        .instrumentBackground()
    }
}

/// Schritt eines Ablaufs wie der Selbstdeinstallation: Name, Zustand als Chip (Text, nicht nur Farbe), beim laufenden
/// Schritt ein kleiner Fortschritt.
public struct ProcedureStep: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let state: StatusItem
    public let isRunning: Bool

    public init(id: String, title: String, state: StatusItem, isRunning: Bool = false) {
        self.id = id
        self.title = title
        self.state = state
        self.isRunning = isRunning
    }

    /// Wert für VoiceOver: der Zustand.
    public var spokenValue: String { state.text }
}

/// Schritte eines Ablaufs untereinander: Name links (der laufende halbfett), rechts Fortschritt und Zustandschip.
/// VoiceOver liest den Namen als Beschriftung, den Zustand als Wert.
public struct ProcedureStepList: View {
    let steps: [ProcedureStep]

    public init(steps: [ProcedureStep]) {
        self.steps = steps
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            ForEach(steps) { step in
                HStack(spacing: InstrumentSpacing.cell) {
                    Text(verbatim: step.title).font(InstrumentFont.body.weight(step.isRunning ? .medium : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: InstrumentSpacing.group)
                    if step.isRunning {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    StatusChip(step.state, isSmall: true)
                }
                .accessibilityReading(Text(verbatim: step.title), value: Text(verbatim: step.spokenValue))
            }
        }
    }
}
