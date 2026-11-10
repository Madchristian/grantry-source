import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung der Darstellung „Erweiterungen“ (ManagerKit) zu den Inhalten der Tafel (GrantryCharts): eine Stelle für Töne,
// Symbole und Texte, damit Radar, Tabelle und Detail dieselbe Erweiterung gleich zeigen.

extension ExtensionTone {
    /// Zustandston der Instrumententafel (§2.5).
    var statusTone: StatusTone {
        switch self {
        case .positive: .positive
        case .info: .info
        case .neutral: .neutral
        case .finding: .finding
        case .critical: .critical
        }
    }
}

extension ExtensionVerdict {
    var statusItems: [StatusItem] { items.map { StatusItem($0.text, tone: $0.tone.statusTone) } }
}

enum ExtensionBoardMapping {
    static func content(_ presentation: ExtensionPresentation, now: Date) -> ExtensionBoardContent {
        ExtensionBoardContent(
            layers: presentation.layers.map(layer), sections: presentation.sections.map(layer),
            radarValue: "\(presentation.all.count)",
            shownText: String(localized: "\(presentation.rows.count) von \(presentation.all.count)"),
            notice: presentation.notice(now: now),
            calm: presentation.isCalm
                ? ExtensionCalmContent(title: ExtensionPresentation.calmTitle, reason: ExtensionPresentation.calmReason,
                                       checks: presentation.calmChecks, note: ExtensionPresentation.calmNote)
                : nil
        )
    }

    static func layer(_ group: ExtensionLayerGroup) -> ExtensionLayerContent {
        ExtensionLayerContent(id: "\(group.layer)", title: group.layer.displayName, ringTitle: group.layer.ringTitle,
                              explanation: group.layer.explanation, rows: group.rows.map(row), note: group.note)
    }

    static func row(_ row: ExtensionRow) -> ExtensionRowContent {
        ExtensionRowContent(
            id: row.id, symbol: row.record.kind.symbol, title: row.title, kind: row.record.kind.displayName,
            vendor: row.vendor ?? "–", vendorDetail: row.teamText, version: row.versionText,
            state: StatusItem(row.record.state.displayName, tone: row.record.state.tone.statusTone),
            rating: rating(row.rating), radarLabel: row.radarLabel
        )
    }

    static func detail(_ detail: ExtensionDetail) -> ExtensionDetailContent {
        let row = detail.row
        return ExtensionDetailContent(
            id: row.id, symbol: row.record.kind.symbol, title: row.title, subtitle: detail.subtitle,
            state: StatusItem(row.record.state.displayName, tone: row.record.state.tone.statusTone),
            rating: rating(row.rating), permission: detail.permission,
            findings: detail.findings.map { StatusItem($0.text, tone: $0.tone.statusTone) },
            acceptance: detail.acceptance?.text,
            facts: detail.facts.map { ExtensionDetailContent.Fact(title: $0.title, value: $0.value, isCode: $0.isCode) }
        )
    }

    private static func rating(_ rating: ExtensionRating?) -> StatusItem? {
        rating.map { StatusItem($0.title, tone: $0.tone.statusTone) }
    }
}
