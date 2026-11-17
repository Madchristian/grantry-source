import GrantryCharts
import ManagerKit
import SwiftUI

/// Was eine Kachel der Tafel im Bearbeitungsmodus meldet; der Editor setzt es in Befehle an der Anordnung um.
enum OverviewEditEvent {
    case select(OverviewTileKind)
    case perform(OverviewEditCommand, OverviewTileKind)
    /// Ziehen der Kachel bzw. ihres Griffs um `translation` (im Raum des Editors), `nil` beim Loslassen.
    case drag(OverviewTileKind, translation: CGSize?)
    case resize(OverviewTileKind, translation: CGSize?)
}

/// Wo im Editor der Tastaturfokus steht: auf einer Kachel der Tafel oder einer des Katalogs.
enum OverviewEditorFocus: Hashable {
    case tile(OverviewTileKind)
    case catalog(OverviewTileKind)
}

/// Tafel im Bearbeitungsmodus (Spec 2026-11-09-uebersicht-baukasten § 5): jede Kachel mit Rahmen, „Entfernen“ und
/// Größengriff; während des Ziehens die Vorschau mit einem Abdruck, wo die Kachel einrasten würde. Tasten der gewählten
/// Kachel: Pfeile verschieben, ⌘+ / ⌘− ändern die Größe, ⌫ entfernt, Tab und ⇧Tab wählen in Lesereihenfolge.
struct OverviewEditableBoard: View {
    /// Anordnung samt Vorschau eines laufenden Ziehens.
    let layout: OverviewBoardLayout
    let selection: OverviewTileKind?
    /// Kachel, die gerade als Kopie am Zeiger hängt (Abdruck statt Inhalt).
    let lifted: OverviewTileKind?
    let source: OverviewTileSource
    let metrics: BoardGridMetrics
    let space: NamedCoordinateSpace
    let focus: FocusState<OverviewEditorFocus?>.Binding
    let handle: (OverviewEditEvent) -> Void

    var body: some View {
        BoardGrid(metrics: metrics) {
            ForEach(OverviewGrid.readingOrder(layout.placements())) { placement in
                OverviewEditableTile(placement: placement, isSelected: placement.kind == selection,
                                     isLifted: placement.kind == lifted, source: source, space: space, handle: handle)
                    .focused(focus, equals: .tile(placement.kind))
                    .boardGridFrame(placement.boardGridFrame)
            }
        }
        .onKeyPress(phases: .down, action: key)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tafel"))
        .accessibilityIdentifier("overviewBoardEditor")
    }

    /// Tasten der gewählten Kachel; andere Tasten gehen weiter (Esc beendet den Editor, Tab am Rand verlässt die Tafel).
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard case .tile(let kind) = focus.wrappedValue else { return .ignored }
        if let command = Self.command(for: press) {
            handle(.perform(command, kind))
            return .handled
        }
        guard press.key == .tab || press.characters == Self.backtab else { return .ignored }
        let forward = press.characters != Self.backtab && !press.modifiers.contains(.shift)
        guard let next = layout.selection(after: kind, forward: forward) else { return .ignored }
        handle(.select(next))
        return .handled
    }

    /// ⇧Tab liefert unter macOS dieses Zeichen.
    private static let backtab = "\u{19}"
    private static let backspace = "\u{7F}"

    private static func command(for press: KeyPress) -> OverviewEditCommand? {
        switch press.key {
        case .leftArrow: return .move(.left)
        case .rightArrow: return .move(.right)
        case .upArrow: return .move(.up)
        case .downArrow: return .move(.down)
        case .delete, .deleteForward: return .remove
        default: break
        }
        // ⌫ kommt unter macOS als U+007F an, nicht als `KeyEquivalent.delete` (U+0008).
        if press.characters == Self.backspace { return .remove }
        guard press.modifiers.contains(.command) else { return nil }
        switch press.characters {
        case "+", "=": return .step(.larger)
        case "-": return .step(.smaller)
        default: return nil
        }
    }
}

/// Kachel der Tafel im Bearbeitungsmodus. Der Inhalt ist nur Anschauung (kein Sprung in den Task-Manager); ein Klick
/// wählt, Ziehen verschiebt, der Griff ändert die Größe. VoiceOver liest „Titel, Zeile, Spalte, Größe“ und bietet
/// dieselben Änderungen als benannte Aktionen.
private struct OverviewEditableTile: View {
    let placement: OverviewTilePlacement
    let isSelected: Bool
    let isLifted: Bool
    let source: OverviewTileSource
    let space: NamedCoordinateSpace
    let handle: (OverviewEditEvent) -> Void

    private var kind: OverviewTileKind { placement.kind }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous)
        ZStack {
            // Trefferfläche der Kachel für Klick und Ziehen; der Inhalt selbst nimmt keine Klicks an. Nicht als
            // `contentShape` des Ganzen: Das schnitte die überstehenden Knöpfe des Rahmens ab.
            shape.fill(.clear).contentShape(shape)
            if isLifted {
                OverviewDropSlot()
            } else {
                OverviewTileContent(kind: kind, span: placement.span, source: source) {}
                    .allowsHitTesting(false)
                OverviewEditChrome(title: kind.title, isSelected: isSelected,
                                   remove: { handle(.perform(.remove, kind)) }, handle: resizeGesture)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onTapGesture { handle(.select(kind)) }
        .gesture(moveGesture)
        .pointerStyle(.grabIdle)
        .contextMenu { OverviewTileMenu(kind: kind, span: placement.span, perform: perform) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: placement.spokenPosition))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityActions {
            ForEach(OverviewMoveDirection.allCases, id: \.self) { direction in
                Button(direction.actionTitle) { perform(.move(direction)) }
            }
            ForEach(kind.allowedSpans.filter { $0 != placement.span }, id: \.self) { span in
                Button(String(localized: "Größe \(span.description)")) { perform(.resize(span)) }
            }
            Button(String(localized: "Entfernen")) { perform(.remove) }
        }
        .accessibilityIdentifier("overviewEditTile.\(kind.rawValue)")
    }

    private func perform(_ command: OverviewEditCommand) {
        handle(.perform(command, kind))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: InstrumentSpacing.inline, coordinateSpace: space)
            .onChanged { handle(.drag(kind, translation: $0.translation)) }
            .onEnded { _ in handle(.drag(kind, translation: nil)) }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: space)
            .onChanged { handle(.resize(kind, translation: $0.translation)) }
            .onEnded { _ in handle(.resize(kind, translation: nil)) }
    }
}

/// Kontextmenü einer Kachel: Größe (alle erlaubten, die aktuelle abgehakt), Verschieben und Entfernen.
private struct OverviewTileMenu: View {
    let kind: OverviewTileKind
    let span: OverviewTileSpan
    let perform: (OverviewEditCommand) -> Void

    var body: some View {
        Picker(String(localized: "Größe"), selection: Binding(get: { span }, set: { perform(.resize($0)) })) {
            ForEach(kind.allowedSpans, id: \.self) { span in
                Text(verbatim: span.description).tag(span)
            }
        }
        Menu(String(localized: "Verschieben")) {
            ForEach(OverviewMoveDirection.allCases, id: \.self) { direction in
                Button(direction.actionTitle) { perform(.move(direction)) }
            }
        }
        Divider()
        Button(String(localized: "Entfernen"), role: .destructive) { perform(.remove) }
    }
}

extension OverviewMoveDirection {
    /// Name der VoiceOver-Aktion und des Menüpunkts.
    var actionTitle: String {
        switch self {
        case .left: String(localized: "Nach links")
        case .right: String(localized: "Nach rechts")
        case .up: String(localized: "Nach oben")
        case .down: String(localized: "Nach unten")
        }
    }
}
