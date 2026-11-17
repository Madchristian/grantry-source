import Foundation

/// Schritt der Größe per ⌘+ und ⌘−.
public enum OverviewSizeStep: Sendable {
    case larger, smaller
}

/// Änderung an einer Kachel im Bearbeitungsmodus (Spec 2026-11-09-uebersicht-baukasten § 5). Maus, Tastatur,
/// Kontextmenü und VoiceOver lösen dieselben Befehle aus, damit alle Wege gleichwertig sind und gleich antworten.
public enum OverviewEditCommand: Equatable, Sendable {
    /// Ein Schritt per Pfeiltaste oder VoiceOver-Aktion.
    case move(OverviewMoveDirection)
    /// Nächste erlaubte Größe (⌘+ / ⌘−).
    case step(OverviewSizeStep)
    /// Größe aus dem Kontextmenü, der VoiceOver-Aktion oder vom Griff.
    case resize(OverviewTileSpan)
    /// Ablegen nach dem Ziehen, von der Tafel oder aus dem Katalog (dort in der Standardgröße).
    case place(OverviewGridCell)
    /// Aus dem Katalog hinten anfügen (wählen und ↩).
    case add
    case remove
}

/// Antwort auf einen Befehl: ob sich die Anordnung geändert hat, was VoiceOver ansagt und die Statuszeile zeigt (neue
/// Lage, oder ein Hinweis, warum es nicht geht) und welche Kachel danach gewählt ist.
public struct OverviewEditResult: Equatable, Sendable {
    public let changed: Bool
    public let message: String
    public let selection: OverviewTileKind?
}

extension OverviewTileKind {
    /// Größe, auf die der Griff einrastet: die erlaubte, die der gezogenen Größe in Zellen am nächsten kommt.
    public func span(columns: Double, rows: Double) -> OverviewTileSpan {
        OverviewTileSpan.nearest(columns: columns, rows: rows, among: allowedSpans) ?? defaultSpan
    }
}

extension OverviewBoardLayout {
    // MARK: - Lesen

    public func placement(of kind: OverviewTileKind) -> OverviewTilePlacement? {
        placements().first { $0.kind == kind }
    }

    /// „Datenträger, Zeile 3, Spalte 3, 2 × 1“ – Zeilen und Spalten ab 1; `nil`, wenn die Kachel fehlt.
    public func spokenPosition(of kind: OverviewTileKind) -> String? {
        placement(of: kind)?.spokenPosition
    }

    /// Nächste erlaubte Größe der Kachel in Richtung `step`; `nil` an der Grenze oder wenn die Kachel fehlt.
    public func span(of kind: OverviewTileKind, stepped step: OverviewSizeStep) -> OverviewTileSpan? {
        guard let span = span(of: kind), let index = kind.allowedSpans.firstIndex(of: span) else { return nil }
        let next = step == .larger ? index + 1 : index - 1
        return kind.allowedSpans.indices.contains(next) ? kind.allowedSpans[next] : nil
    }

    /// Tab und ⇧Tab: die nächste bzw. vorige Kachel in Lesereihenfolge; ohne gewählte Kachel (oder eine, die fehlt) die
    /// erste bzw. letzte. `nil` hinter dem Ende: Der Fokus verlässt die Tafel.
    public func selection(after kind: OverviewTileKind?, forward: Bool) -> OverviewTileKind? {
        let order = OverviewGrid.readingOrder(placements()).map(\.kind)
        guard let kind, let index = order.firstIndex(of: kind) else { return forward ? order.first : order.last }
        let next = forward ? index + 1 : index - 1
        return order.indices.contains(next) ? order[next] : nil
    }

    // MARK: - Ändern

    /// Führt einen Befehl aus. Ohne Änderung bleibt die Anordnung gleich, und die Antwort sagt, warum. Jede Änderung
    /// steht vor `answer` in einer eigenen Zeile: Als Argument liefe sie erst, nachdem `answer` den alten Stand gelesen hat.
    @discardableResult
    public mutating func apply(_ command: OverviewEditCommand, to kind: OverviewTileKind) -> OverviewEditResult {
        let title = kind.title
        switch command {
        case .add, .place: break
        case .move, .step, .resize, .remove:
            guard contains(kind) else { return refused(kind, String(localized: "\(title) ist nicht auf der Tafel")) }
        }
        switch command {
        case .move(let direction):
            let moved = move(kind, direction)
            return answer(kind, changed: moved,
                          refusal: String(localized: "\(title) lässt sich nicht weiter \(direction.spokenName) verschieben"))
        case .step(let step):
            guard let span = span(of: kind, stepped: step) else {
                return refused(kind, step == .larger ? String(localized: "\(title) hat schon die größte Größe")
                                                     : String(localized: "\(title) hat schon die kleinste Größe"))
            }
            let resized = resize(kind, to: span)
            return answer(kind, changed: resized)
        case .resize(let span):
            guard kind.allowedSpans.contains(span) else {
                return refused(kind, String(localized: "\(title) gibt es nicht in \(span.description)"))
            }
            let resized = resize(kind, to: span)
            return answer(kind, changed: resized)
        case .place(let target):
            let placed = place(kind, at: target)
            return answer(kind, changed: placed)
        case .add:
            let inserted = insert(kind)
            return answer(kind, changed: inserted, refusal: String(localized: "\(title) ist schon auf der Tafel"))
        case .remove:
            let neighbour = selection(after: kind, forward: true) ?? selection(after: kind, forward: false)
            remove(kind)
            return OverviewEditResult(changed: true, message: String(localized: "\(title) entfernt"),
                                      selection: neighbour)
        }
    }

    // MARK: - Hilfen

    /// Nach einer Änderung die neue Lage; ohne Änderung der Hinweis oder, wenn es keinen gibt (Ablegen an derselben
    /// Stelle, gleiche Größe), die unveränderte Lage.
    private func answer(_ kind: OverviewTileKind, changed: Bool, refusal: String? = nil) -> OverviewEditResult {
        guard let position = spokenPosition(of: kind) else { return refused(kind, refusal ?? "") }
        return OverviewEditResult(changed: changed, message: changed ? position : refusal ?? position,
                                  selection: kind)
    }

    private func refused(_ kind: OverviewTileKind, _ message: String) -> OverviewEditResult {
        OverviewEditResult(changed: false, message: message, selection: contains(kind) ? kind : nil)
    }
}

extension OverviewTilePlacement {
    /// „Datenträger, Zeile 3, Spalte 3, 2 × 1“ – Zeilen und Spalten ab 1, für VoiceOver und die Statuszeile.
    public var spokenPosition: String {
        String(localized: "\(kind.title), Zeile \(anchor.row + 1), Spalte \(anchor.column + 1), \(span.description)")
    }
}

extension OverviewMoveDirection {
    /// „nach links“ für Hinweise.
    var spokenName: String {
        switch self {
        case .left: String(localized: "nach links")
        case .right: String(localized: "nach rechts")
        case .up: String(localized: "nach oben")
        case .down: String(localized: "nach unten")
        }
    }
}
