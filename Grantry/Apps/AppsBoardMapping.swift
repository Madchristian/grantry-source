import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung der Apps (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-2.5, #542): Zustandszeile, Listenzeilen
// und Detail an einer Stelle. Akzeptiertes Risiko erscheint nur hier als Chip (Spec §11.2 f).

enum AppsBoardMapping {
    /// Chip „akzeptiert“ an Zeile und Kopf einer App, deren Risiko akzeptiert ist.
    static let acceptedBadge = InstrumentBadge(String(localized: "akzeptiert"), tone: .neutral,
                                               spoken: String(localized: "Risiko akzeptiert"))

    /// Kennung der Listenzeilen für die Performance-UI-Tests.
    static let rowIdentifier = "appRow"
    /// Kennung der Liste für die Performance-UI-Tests.
    static let listIdentifier = "appList"

    // MARK: - Zustandszeile

    /// Zustandszeile (Spec §11.2 a) über alle installierten Apps, unabhängig von Suche und Filter.
    static func head(_ presentation: PresentationSnapshot?, acceptedCount: Int, scannedAt: Date?) -> InventoryHead {
        guard let presentation else {
            return InventoryVerdict.notScanned.head(facts: String(localized: "kein Scan seit dem Start"))
        }
        let apps = presentation.installedApps
        let coverage = presentation.coverage[.apps]
        let accepted = acceptedCount > 0
            ? SystemVerdict.Item(text: String(localized: "\(acceptedCount) akzeptiert"), tone: .neutral) : nil
        let verdict = InventoryVerdict(entryBadges: apps.map { presentation.badges.badges(for: $0.id) }, subject: .apps,
                                       extra: accepted,
                                       missingSources: coverage.map { $0.isComplete ? 0 : max($0.gaps.count, 1) } ?? 0)
        var facts = apps.count == 1 ? String(localized: "1 App") : String(localized: "\(apps.count) Apps")
        if let scannedAt {
            facts += " · " + String(localized: "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))")
        }
        return verdict.head(facts: facts)
    }

    // MARK: - Liste

    /// Gruppen „Mit Befund“ und „Übrige“ bei Sortierung nach Name, sonst eine Gruppe „Alle Apps“ in der gewählten
    /// Reihenfolge (Spec §11.2 b).
    static func sections(_ rows: [InstalledAppRow], sort: AppSortOrder,
                         item: (InstalledAppRow) -> InstrumentListItem<String>) -> [InstrumentListSection<String>] {
        guard sort == .name else {
            return rows.isEmpty ? [] : [InstrumentListSection(id: "alle", title: String(localized: "Alle Apps"),
                                                              items: rows.map(item))]
        }
        return PermissionsBoardMapping.sections(rows, isFlagged: \.isFlagged, item: item)
    }

    /// Zeile: Name, „Entwickler · Größe · zuletzt benutzt“, Badges als Chips und „akzeptiert“; Befund-Punkt wie die
    /// Gruppe „Mit Befund“.
    static func item(_ row: InstalledAppRow, badges: [RecordBadge], isLoading: Bool,
                     isRiskAccepted: Bool) -> InstrumentListItem<String> {
        let detail = isLoading
            ? [row.listDetail, String(localized: "Nutzung wird ermittelt …")].joined(separator: " · ") : row.listDetail
        return InstrumentListItem(
            id: row.id,
            content: InstrumentRowContent(symbol: "app", title: row.app.name, detail: detail,
                                          badges: badges.map(\.instrumentBadge) + (isRiskAccepted ? [acceptedBadge] : []),
                                          finding: row.isFlagged),
            accessibilityIdentifier: rowIdentifier
        )
    }

    // MARK: - Detail

    /// Gruppen im Detail; Knöpfe und Sprungzeilen bringt `InstalledAppDetailView` über `accessory`.
    enum GroupID {
        static let notes = "hinweise"
        static let acceptance = "einschaetzung"
        static let acceptedNotes = "akzeptiert"
        static let facts = "angaben"
        static let place = "ort"
        static let grants = "berechtigungen"
        static let autostart = "autostart"
        static let extensions = "erweiterungen"
    }

    /// Detail einer App (Spec §11.2 c bis f): Hinweise direkt unter Kopf und Knopfzeile, eigene Einschätzung, bei
    /// akzeptiertem Risiko die Prüfhinweise ruhig unter eigener Überschrift, Angaben, Ort und die Sprunggruppen.
    static func detail(_ detail: InstalledAppDetail, presentation: PresentationSnapshot,
                       isRiskAccepted: Bool) -> RecordDetailContent {
        let app = detail.app
        let notes = detail.findings.map { DetailNoteContent($0.message, kind: RecordBadge.review($0.severity).noteKind) }
        var groups: [DetailGroupContent] = []
        if !isRiskAccepted, !notes.isEmpty {
            groups.append(DetailGroupContent(id: GroupID.notes, title: String(localized: "Hinweise"), count: notes.count,
                                             notes: notes))
        }
        groups.append(DetailGroupContent(id: GroupID.acceptance, title: String(localized: "Eigene Einschätzung")))
        if isRiskAccepted, !notes.isEmpty {
            groups.append(DetailGroupContent(id: GroupID.acceptedNotes, title: String(localized: "Akzeptierte Prüfhinweise"),
                                             count: notes.count,
                                             notes: notes.map { DetailNoteContent($0.text, kind: .info) }))
        }
        groups.append(DetailGroupContent(
            id: GroupID.facts, title: String(localized: "Angaben"),
            facts: detail.facts.map { DetailFactContent($0.label, value: $0.value, tone: $0.tone?.statusTone) },
            notes: detail.signingNote.map { [DetailNoteContent($0, kind: .info)] } ?? []
        ))
        groups.append(DetailGroupContent(id: GroupID.place, title: String(localized: "Ort"),
                                         facts: [DetailFactContent(String(localized: "Pfad"), value: detail.pathText,
                                                                   isCode: true)]))
        let links = [(GroupID.grants, String(localized: "Berechtigungen"), detail.grants.count),
                     (GroupID.autostart, String(localized: "Autostart"), detail.autostartItems.count),
                     (GroupID.extensions, String(localized: "Erweiterungen"), detail.extensions.count)]
        groups += links.filter { $0.2 > 0 }.map { DetailGroupContent(id: $0.0, title: $0.1, count: $0.2) }
        return RecordDetailContent(
            symbol: "app", title: app.name, subtitle: app.bundleID ?? app.originDetail,
            items: presentation.badges.badges(for: app.id).map(\.statusItem)
                + (isRiskAccepted ? [StatusItem(acceptedBadge.title, tone: acceptedBadge.tone)] : []),
            finding: FindingFilter.flagged.includes(presentation.highestSeverity(for: app.id)),
            groups: groups
        )
    }

    /// Eigene Einschätzung; `error` ist der Fehler beim Speichern bzw. Laden.
    static func acceptance(isRiskAccepted: Bool, error: String?) -> RiskAcceptanceContent {
        RiskAcceptanceContent(
            isAccepted: isRiskAccepted,
            explanation: isRiskAccepted
                ? String(localized: "Du vertraust dieser App. Ihre App-Warnungen sind ausgeblendet. Bei einem Wechsel des Entwicklerteams wird erneut gewarnt.")
                : String(localized: "Wenn du diese App kennst und ihr vertraust, kannst du ihre App-Warnungen ausblenden. Die Prüfergebnisse bleiben einsehbar."),
            error: error
        )
    }

    /// Berechtigung einer App als Sprungzeile: Dienst, Bereich, Prüf-Badges und Zustand.
    static func grantRow(_ grant: PermissionGrant, presentation: PresentationSnapshot) -> InstrumentRowContent {
        InstrumentRowContent(symbol: "hand.raised", title: grant.serviceName, detail: grant.scope.displayName,
                             badges: presentation.badges.badges(for: grant.id).map(\.instrumentBadge),
                             status: StatusItem(grant.authValue.displayName, tone: grant.authValue.tone.statusTone),
                             finding: presentation.highestSeverity(for: grant.id) != nil)
    }

    /// Mitgebrachte Erweiterung als Sprungzeile: Name, Art und Zustand, Prüf-Badges.
    static func extensionRow(_ reference: ExtensionReference, presentation: PresentationSnapshot) -> InstrumentRowContent {
        InstrumentRowContent(symbol: reference.symbol, title: reference.title, detail: reference.subtitle,
                             badges: presentation.badges.badges(for: reference.id).map(\.instrumentBadge),
                             finding: presentation.highestSeverity(for: reference.id) != nil)
    }
}

extension AutostartItem {
    /// Autostart-Eintrag als Zeilenkopf einer Sprungzeile: Label, Programm, Prüf-Badges, aktiv bzw. deaktiviert.
    func jumpRowContent(badges: [RecordBadge]) -> InstrumentRowContent {
        let status = statusBadges.first.map { StatusItem($0.title, tone: $0.tone.statusTone) }
        return InstrumentRowContent(symbol: kind.systemImage, title: label, detail: program ?? kind.sectionTitle,
                                    badges: badges.map(\.instrumentBadge), status: status,
                                    finding: badges.contains { if case .review = $0 { true } else { false } })
    }
}
