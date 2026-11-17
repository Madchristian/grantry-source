import GrantryCharts
import ManagerKit
import SwiftUI

/// Tafel im Bearbeitungsmodus (Spec 2026-11-09-uebersicht-baukasten § 5), eingebunden im Popover und in den
/// Einstellungen: Kacheln ziehen (mit Vorschau und Einrasten), per Griff in der Größe ändern, entfernen, aus dem Katalog
/// hinzufügen; „Standard“ nach Rückfrage, „Fertig“ oder Esc beendet. Tastatur und VoiceOver lösen dieselben Befehle aus
/// (`OverviewEditCommand`); jede Änderung sagt VoiceOver die neue Lage an, was nicht geht, meldet die Statuszeile.
/// Animiert wird nur beim Ziehen und Einrasten, nie je Messtakt.
struct OverviewBoardEditor: View {
    @Binding var layout: OverviewBoardLayout
    /// Eingerichtete Quellen dieses Macs: Katalog und Standard ohne nicht verfügbare Kacheln.
    let configured: Set<TaskManagerSource>
    let source: OverviewTileSource
    let metrics: BoardGridMetrics
    let done: () -> Void

    @State private var selection: OverviewTileKind?
    @State private var gesture: OverviewEditGesture?
    /// Ansage der letzten Änderung samt der Kachel, die danach gewählt war; die Statuszeile zeigt sie, solange diese
    /// gewählt bleibt (auch wenn der Fokus kurz woanders landet, etwa beim Einfügen aus dem Katalog).
    @State private var message: (kind: OverviewTileKind?, text: String)?
    @State private var confirmingReset = false
    @State private var pointer = OverviewDragPointer()
    /// Linke obere Ecke der Tafel im Raum des Editors (Ziehen aus dem Katalog, schwebende Kopie).
    @State private var boardOrigin = CGPoint.zero
    @FocusState private var focus: OverviewEditorFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = NamedCoordinateSpace.named("overviewBoardEditor")

    /// - Parameter selection: anfangs gewählte Kachel (Vorschau und Snapshots).
    init(layout: Binding<OverviewBoardLayout>, configured: Set<TaskManagerSource>, source: OverviewTileSource,
         metrics: BoardGridMetrics, selection: OverviewTileKind? = nil, done: @escaping () -> Void) {
        _layout = layout
        self.configured = configured
        self.source = source
        self.metrics = metrics
        self.done = done
        _selection = State(initialValue: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            OverviewEditorHead(canReset: layout != .standard(configured: configured),
                               confirmingReset: $confirmingReset, reset: reset, done: done)
            OverviewEditableBoard(layout: gesture?.preview(of: layout) ?? layout, selection: selection,
                                  lifted: gesture?.lifts == true ? gesture?.kind : nil, source: source,
                                  metrics: metrics, space: Self.space, focus: $focus, handle: handle)
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: Self.space).origin } action: { boardOrigin = $0 }
            OverviewTileCatalog(kinds: layout.addableKinds(configured: configured), space: Self.space, focus: $focus,
                                add: { perform(.add, on: $0) }, drag: dragFromCatalog)
            OverviewEditorStatus(text: status)
        }
        .coordinateSpace(Self.space)
        .overlay(alignment: .topLeading) {
            if let gesture, gesture.lifts {
                OverviewDragCopy(kind: gesture.kind, span: gesture.span, source: source, metrics: metrics,
                                 pointer: pointer)
            }
        }
        .onExitCommand(perform: done)
        .onChange(of: focus) {
            // Tab oder Klick auf eine Kachel wählt sie.
            if case .tile(let kind) = focus { selection = kind }
        }
    }

    // MARK: - Befehle

    private var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.2) }

    private func handle(_ event: OverviewEditEvent) {
        switch event {
        case .select(let kind):
            message = nil
            select(kind)
        case .perform(let command, let kind):
            perform(command, on: kind)
        case .drag(let kind, let translation):
            drag(kind, by: translation)
        case .resize(let kind, let translation):
            resize(kind, by: translation)
        }
    }

    /// Führt einen Befehl aus, beendet ein laufendes Ziehen und sagt Lage oder Hinweis an. Animiert nur beim Einrasten
    /// nach dem Ziehen.
    private func perform(_ command: OverviewEditCommand, on kind: OverviewTileKind, animated: Bool = false) {
        var result: OverviewEditResult?
        withAnimation(animated ? motion : nil) {
            result = layout.apply(command, to: kind)
            gesture = nil
        }
        guard let result else { return }
        select(result.selection)
        announce(result.message, for: result.selection)
    }

    /// Wählt die Kachel und gibt ihr den Fokus, erst im nächsten Durchlauf: Eine gerade eingefügte Kachel gibt es vorher
    /// noch nicht als Ansicht, der Fokus ginge sonst ins Leere.
    private func select(_ kind: OverviewTileKind?) {
        selection = kind
        Task { @MainActor in focus = kind.map(OverviewEditorFocus.tile) }
    }

    private func announce(_ text: String, for kind: OverviewTileKind?) {
        message = (kind, text)
        AccessibilityNotification.Announcement(text).post()
    }

    private func reset() {
        withAnimation(motion) { layout = .standard(configured: configured) }
        confirmingReset = false
        select(nil)
        announce(String(localized: "Standard wiederhergestellt"), for: nil)
    }

    // MARK: - Ziehen

    /// Kachel der Tafel um `translation` verschoben; `nil` legt sie ab.
    private func drag(_ kind: OverviewTileKind, by translation: CGSize?) {
        guard let translation else { return finishGesture() }
        guard let placement = layout.placement(of: kind) else { return }
        let start = metrics.frame(of: placement.boardGridFrame).origin
        let origin = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
        follow(origin)
        update(OverviewEditGesture(kind: kind, mode: .move, span: placement.span,
                                   target: metrics.dropCell(forOrigin: origin)))
    }

    /// Kachel aus dem Katalog am Punkt `location` (Raum des Editors); der Zeiger hält sie in der Mitte ihrer ersten
    /// Zelle. Neben der Tafel gibt es kein Ziel, Loslassen dort bricht ab.
    private func dragFromCatalog(_ kind: OverviewTileKind, location: CGPoint?) {
        guard let location else { return finishGesture() }
        let point = CGPoint(x: location.x - boardOrigin.x, y: location.y - boardOrigin.y)
        let origin = CGPoint(x: point.x - metrics.columnWidth / 2, y: point.y - metrics.rowHeight / 2)
        follow(origin)
        let rows = OverviewBoardLayout.grid.rowCount(of: layout.placements())
        update(OverviewEditGesture(kind: kind, mode: .add, span: kind.defaultSpan,
                                   target: metrics.accepts(point, rows: rows) ? metrics.dropCell(forOrigin: origin) : nil))
    }

    /// Größengriff um `translation` gezogen; die Größe rastet auf die nächste erlaubte ein.
    private func resize(_ kind: OverviewTileKind, by translation: CGSize?) {
        guard let translation else { return finishGesture() }
        guard let placement = layout.placement(of: kind) else { return }
        let span = metrics.resizedSpan(of: kind, frame: metrics.frame(of: placement.boardGridFrame),
                                       translation: translation)
        update(OverviewEditGesture(kind: kind, mode: .resize, span: span, target: nil))
    }

    /// Schwebende Kopie an die linke obere Ecke `origin` (Raum der Tafel); zeichnet nur die Kopie neu.
    private func follow(_ origin: CGPoint) {
        pointer.origin = CGPoint(x: boardOrigin.x + origin.x, y: boardOrigin.y + origin.y)
    }

    /// Neue Vorschau nur, wenn sich Zielzelle oder Größe ändern.
    private func update(_ next: OverviewEditGesture) {
        if gesture == nil, next.mode != .add {
            message = nil
            select(next.kind)
        }
        guard next != gesture else { return }
        withAnimation(motion) { gesture = next }
    }

    private func finishGesture() {
        guard let finished = gesture else { return }
        guard let command = finished.command else {
            withAnimation(motion) { gesture = nil }
            return
        }
        perform(command, on: finished.kind, animated: true)
    }

    // MARK: - Statuszeile

    private var status: String {
        if let message, message.kind == selection { return message.text }
        if case .catalog(let kind) = focus {
            return String(localized: "\(kind.title): ↩ fügt hinten an · auf die Tafel ziehen setzt sie an die Stelle")
        }
        if let selection, let span = layout.span(of: selection) {
            return String(localized: "Gewählt: \(selection.title), \(span.description) · ←→↑↓ verschieben · ⌘+ / ⌘− Größe · ⌫ entfernen")
        }
        return String(localized: "Kachel wählen per Klick oder Tab · Ziehen verschiebt · Griff rechts unten ändert die Größe")
    }
}

/// Kopf des Editors: Titel, „Standard“ mit Rückfrage und „Fertig“. Selbst gezeichnete Knöpfe, damit Snapshots sie zeigen
/// (`ImageRenderer` zeichnet keine AppKit-Knöpfe).
private struct OverviewEditorHead: View {
    let canReset: Bool
    @Binding var confirmingReset: Bool
    let reset: () -> Void
    let done: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            HStack(spacing: InstrumentSpacing.bar) {
                PeilHead(String(localized: "Übersicht anpassen"))
                Button { confirmingReset = true } label: {
                    Label("Standard", systemImage: "arrow.counterclockwise").font(InstrumentFont.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canReset ? environment.statusTextColor(.info) : .instrumentSecondary)
                .disabled(!canReset || confirmingReset)
                .help("Übersicht auf den Standard zurücksetzen")
                Button(action: done) {
                    Label("Fertig", systemImage: "checkmark")
                        .font(InstrumentFont.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, InstrumentSpacing.cell)
                        .padding(.vertical, InstrumentSpacing.stack)
                        .background(Capsule().fill(GrantryBrand.fill))
                }
                .buttonStyle(.plain)
                .help("Bearbeiten beenden (Esc)")
                .accessibilityIdentifier("overviewEditorDone")
            }
            if confirmingReset {
                OverviewResetConfirmation(cancel: { confirmingReset = false }, reset: reset)
            }
        }
    }
}

/// Rückfrage zu „Standard“ in der Tafel selbst statt als Dialog, der im Popover ein eigenes Fenster bräuchte.
private struct OverviewResetConfirmation: View {
    let cancel: () -> Void
    let reset: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: InstrumentSpacing.bar) {
            Text("Auf den Standard zurücksetzen? Die eigene Anordnung geht verloren.")
                .font(InstrumentFont.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Abbrechen", action: cancel)
                .buttonStyle(.plain)
                .foregroundStyle(environment.statusTextColor(.info))
                .keyboardShortcut(.cancelAction)
            Button("Zurücksetzen", role: .destructive, action: reset)
                .buttonStyle(.plain)
                .font(InstrumentFont.body.weight(.semibold))
                .foregroundStyle(environment.statusTextColor(.critical))
        }
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overviewResetConfirmation")
    }
}

/// Statuszeile: gewählte Kachel mit den Tasten, Lage nach einer Änderung oder Hinweis, warum etwas nicht geht.
private struct OverviewEditorStatus: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(InstrumentFont.label)
            .foregroundStyle(.instrumentSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("overviewEditorStatus")
    }
}

/// Kopie der gezogenen Kachel am Zeiger. Liest als Einzige die Lage des Zeigers, damit eine Mausbewegung nur sie neu
/// zeichnet.
private struct OverviewDragCopy: View {
    let kind: OverviewTileKind
    let span: OverviewTileSpan
    let source: OverviewTileSource
    let metrics: BoardGridMetrics
    let pointer: OverviewDragPointer

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = metrics.frame(of: BoardGridFrame(column: 0, row: 0, columns: span.columns, rows: span.rows)).size
        OverviewTileContent(kind: kind, span: span, source: source) {}
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous)
                .strokeBorder(GrantryBrand.focus(colorScheme), lineWidth: InstrumentStroke.focus))
            .offset(x: pointer.origin.x, y: pointer.origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// `TaskManagerPreviewData` gibt es nur im Debug-Build.
#if DEBUG
extension OverviewBoardEditor {
    /// Bearbeiten wie im Entwurf (Spec § 5, Bild „Bearbeiten“): GPU und Arbeitsspeicher auf 1 × 1, Akku und Laufzeit im
    /// Katalog, Datenträger gewählt; im Popover-Rahmen. Für die Vorschau und den Snapshot „overview-editor“.
    static var sample: some View {
        let configured = Set(TaskManagerSource.allCases)
        let layout = sampleLayout
        let sample = TaskManagerPreviewData.overviewSample(performance: 12, efficiency: 4, name: "Apple M4 Max")
        let overview = MenuBarOverviewPresentation.overview(for: sample.frame.snapshot, profile: sample.profile,
                                                            context: sample.context)
        return OverviewBoardEditor(layout: .constant(layout), configured: configured,
                                   source: OverviewTileSource(overview: overview, history: nil),
                                   metrics: BoardGridMetrics(width: sampleSize.width - 2 * InstrumentSpacing.page),
                                   selection: .disk) {}
            .padding(InstrumentSpacing.page)
            .frame(width: sampleSize.width)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Standard mit GPU und Arbeitsspeicher in 1 × 1, ohne Akku und Laufzeit (die im Katalog stehen).
    private static var sampleLayout: OverviewBoardLayout {
        var layout = OverviewBoardLayout.standard(configured: Set(TaskManagerSource.allCases))
        layout.remove(.battery)
        layout.remove(.uptime)
        layout.resize(.gpu, to: .small)
        layout.resize(.memory, to: .small)
        return layout
    }

    /// Popoverbreite; hoch genug für die Zeilen der Tafel, Katalog und Statuszeile.
    static var sampleSize: CGSize {
        let metrics = BoardGridMetrics(width: 440 - 2 * InstrumentSpacing.page)
        let rows = OverviewGrid().rowCount(of: sampleLayout.placements())
        return CGSize(width: 440, height: metrics.height(rows: rows) + 160)
    }
}

#Preview("Übersicht anpassen") {
    OverviewBoardEditor.sample
        .instrumentBackground()
}
#endif
