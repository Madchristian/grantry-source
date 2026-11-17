import GrantryCharts
import ManagerKit
import SwiftUI

/// Laufendes Ziehen im Bearbeitungsmodus (Spec 2026-11-09-uebersicht-baukasten § 3, § 5): eine Kachel verschieben, aus
/// dem Katalog hinzufügen oder per Griff in der Größe ändern. Hält nur, was die Vorschau braucht (Zielzelle bzw.
/// eingerastete Größe); die Tafel rechnet ihre Lage also nur neu, wenn sich eines davon ändert, nicht je Mausbewegung.
struct OverviewEditGesture: Equatable {
    enum Mode: Equatable {
        /// Kachel der Tafel verschieben.
        case move
        /// Kachel aus dem Katalog hineinziehen.
        case add
        /// Größengriff.
        case resize
    }

    let kind: OverviewTileKind
    let mode: Mode
    var span: OverviewTileSpan
    /// Zelle, an der die Kachel einrasten würde; `nil`, solange eine Kachel aus dem Katalog nicht über der Tafel ist.
    var target: OverviewGridCell?

    /// Anordnung, wie sie beim Loslassen würde.
    func preview(of layout: OverviewBoardLayout) -> OverviewBoardLayout {
        switch mode {
        case .move, .add:
            guard let target else { return layout }
            return layout.placing(kind, span: span, at: target)
        case .resize:
            var resized = layout
            resized.resize(kind, to: span)
            return resized
        }
    }

    /// Befehl beim Loslassen; `nil` bricht ab (aus dem Katalog neben der Tafel losgelassen).
    var command: OverviewEditCommand? {
        switch mode {
        case .move, .add: target.map(OverviewEditCommand.place)
        case .resize: .resize(span)
        }
    }

    /// Die gezogene Kachel liegt als Abdruck in der Tafel und folgt als Kopie dem Zeiger (nicht beim Größengriff).
    var lifts: Bool { mode != .resize }
}

/// Lage der schwebenden Kopie beim Ziehen (linke obere Ecke im Raum des Editors). Eigenes Modell, damit eine
/// Mausbewegung nur die Kopie neu zeichnet, nicht Tafel und Katalog.
@MainActor @Observable
final class OverviewDragPointer {
    var origin: CGPoint = .zero
}

extension BoardGridMetrics {
    /// Zelle, an der eine gezogene Kachel mit der linken oberen Ecke `origin` einrastet: die Zelle unter der Mitte ihrer
    /// ersten Zelle, damit sie zur nächsten Zelle rundet statt abzuschneiden.
    func dropCell(forOrigin origin: CGPoint) -> OverviewGridCell {
        cell(at: CGPoint(x: origin.x + columnWidth / 2, y: origin.y + rowHeight / 2)).overviewCell
    }

    /// Größe in Zellen, auf die ein Griff einrastet, wenn die Kachel `frame` um `translation` gezogen wird.
    func resizedSpan(of kind: OverviewTileKind, frame: CGRect, translation: CGSize) -> OverviewTileSpan {
        let size = cells(for: CGSize(width: frame.width + translation.width, height: frame.height + translation.height))
        return kind.span(columns: size.columns, rows: size.rows)
    }

    /// Ob ein Punkt (im Raum der Tafel) so nah an der Tafel liegt, dass eine Kachel aus dem Katalog dort einrastet: über
    /// den Kacheln oder in der Zeile darunter.
    func accepts(_ point: CGPoint, rows: Int) -> Bool {
        (-spacing...width + spacing).contains(point.x)
            && (-spacing...height(rows: rows) + spacing + rowHeight).contains(point.y)
    }
}
