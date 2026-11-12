import Foundation
import GrantryCharts
import ManagerKit

// Zuordnung der Berechtigungen (ManagerKit) zu den Inhalten der Tafel (GrantryCharts, LB-2.2, #539): eine Stelle für
// Zustandszeile, Listenzeilen, Kopf und Einträge im Detail, damit beide Gruppierungen dieselbe Berechtigung gleich zeigen.

extension SystemVerdict.Item {
    var statusItem: StatusItem { StatusItem(text, tone: tone.statusTone) }
}

extension InventoryVerdict {
    /// Zustandszeile mit Anzahl und Scanzeit rechts.
    func head(facts: String) -> InventoryHead {
        InventoryHead(verdict: title, shield: shield.shieldForm, items: items.map(\.statusItem), facts: facts)
    }
}

extension RecordBadge {
    /// Badge als Chip im Kopf des Details.
    var statusItem: StatusItem { StatusItem(title, tone: tone.statusTone) }
}

enum PermissionsBoardMapping {
    /// Zustandszeile (Spec §11.2 a) über alle Apps mit Berechtigungen, unabhängig von Suche und Filter.
    static func head(_ presentation: PresentationSnapshot?, scannedAt: Date?) -> InventoryHead {
        guard let presentation else {
            return InventoryVerdict.notScanned.head(facts: String(localized: "kein Scan seit dem Start"))
        }
        let groups = presentation.appGroups.filter { !$0.grants.isEmpty }
        let coverage = presentation.coverage[.permissions]
        let verdict = InventoryVerdict(entryBadges: groups.map { presentation.badges.badges(forAll: $0.grants.map(\.id)) },
                                       subject: .apps,
                                       missingSources: coverage.map { $0.isComplete ? 0 : max($0.gaps.count, 1) } ?? 0)
        let grants = groups.reduce(0) { $0 + $1.grants.count }
        var facts = String(localized: "\(groups.count) Apps · \(grants) Berechtigungen")
        if let scannedAt {
            facts += " · " + String(localized: "Scan \(scannedAt.formatted(date: .omitted, time: .shortened))")
        }
        return verdict.head(facts: facts)
    }

    /// Liste in den Gruppen „Mit Befund“ und „Übrige“ (Spec §11.2 b); leere Gruppen fallen weg.
    static func sections<Group>(_ groups: [Group], isFlagged: (Group) -> Bool,
                                item: (Group) -> InstrumentListItem<String>) -> [InstrumentListSection<String>] {
        let flagged = groups.filter(isFlagged).map(item)
        let others = groups.filter { !isFlagged($0) }.map(item)
        return [
            flagged.isEmpty ? nil : InstrumentListSection(id: "befund", title: String(localized: "Mit Befund"),
                                                          finding: true, items: flagged),
            others.isEmpty ? nil : InstrumentListSection(id: "uebrige", title: String(localized: "Übrige"),
                                                         items: others),
        ].compactMap(\.self)
    }

    static func appItem(_ group: AppGroup, presentation: PresentationSnapshot) -> InstrumentListItem<String> {
        InstrumentListItem(id: group.id, content: InstrumentRowContent(
            symbol: "app", title: group.app.displayName,
            detail: group.grants.map(\.serviceName).joined(separator: ", "),
            badges: badges(group.grants, presentation: presentation).map(\.instrumentBadge), finding: group.isFlagged
        ))
    }

    static func serviceItem(_ group: ServiceGroup, presentation: PresentationSnapshot) -> InstrumentListItem<String> {
        InstrumentListItem(id: group.id, content: InstrumentRowContent(
            symbol: "hand.raised", title: group.service.displayName, detail: appCount(group.grants.count),
            badges: badges(group.grants, presentation: presentation).map(\.instrumentBadge), finding: group.isFlagged
        ))
    }

    // MARK: - Detail

    static func appDetail(_ group: AppGroup, presentation: PresentationSnapshot,
                          runningRecordID: String?) -> GrantDetailContent {
        let app = group.app
        var facts = [DetailFactContent(String(localized: "Signatur"), value: app.signing.fullText,
                                       tone: app.signing.tone.statusTone)]
        if let path = app.path {
            facts.append(DetailFactContent(String(localized: "Pfad"), value: path, isCode: true))
        }
        if app.presence != .present {
            facts.append(DetailFactContent(String(localized: "Auf dem Mac"), value: app.presence.displayName))
        }
        return GrantDetailContent(
            symbol: "app", title: app.displayName, subtitle: app.bundleID ?? "",
            items: badges(group.grants, presentation: presentation).map(\.statusItem), finding: group.isFlagged,
            facts: facts, grantsTitle: String(localized: "Berechtigungen"),
            emptyGrantsText: String(localized: "Keine Berechtigungen"),
            grants: group.grants.map { grant(of: $0, subject: .service, presentation: presentation,
                                             runningRecordID: runningRecordID) }
        )
    }

    static func serviceDetail(_ group: ServiceGroup, presentation: PresentationSnapshot,
                              runningRecordID: String?) -> GrantDetailContent {
        GrantDetailContent(
            symbol: "hand.raised", title: group.service.displayName, subtitle: group.service.id,
            items: [StatusItem(appCount(group.grants.count), tone: .neutral)], finding: group.isFlagged,
            grantsTitle: String(localized: "Apps"), emptyGrantsText: String(localized: "Keine Berechtigungen"),
            grants: group.grants.map { grant(of: $0, subject: .app, presentation: presentation,
                                             runningRecordID: runningRecordID) }
        )
    }

    /// Eine Berechtigung im Detail: in der App-Ansicht benannt nach dem Dienst, in der Dienst-Ansicht nach der App; Zustand
    /// als Chip, Prüf- und Aufräumhinweise sowie der Grund, warum Grantry sie nicht zurücksetzen kann.
    static func grant(of grant: PermissionGrant, subject: GrantSubject, presentation: PresentationSnapshot,
                      runningRecordID: String?) -> GrantEntryContent {
        let date = grant.lastModified.formatted(date: .abbreviated, time: .omitted)
        let title = switch subject {
        case .service: grant.serviceName
        case .app: grant.target.map { String(localized: "\(grant.client.displayName) (Ziel: \($0))") }
            ?? grant.client.displayName
        }
        var notes = presentation.findings(for: grant.id).map { DetailNoteContent($0.message, kind: .finding) }
        if let cleanup = presentation.cleanupHint(for: grant.id) {
            notes.append(DetailNoteContent(cleanup.message, kind: .info))
        }
        if case .readOnly(let reason) = GrantActions.policy.availability(for: grant) {
            notes.append(DetailNoteContent(reason.description, kind: .locked))
        }
        let isRunning = [grant.id, ServiceReset.recordID(for: grant.service)].contains(runningRecordID)
        return GrantEntryContent(
            id: grant.id,
            row: InstrumentRowContent(
                symbol: "hand.raised", title: title,
                detail: String(localized: "\(grant.scope.displayName) · geändert am \(date)"),
                badges: presentation.badges.badges(for: grant.id).map(\.instrumentBadge),
                status: StatusItem(grant.authValue.displayName, tone: grant.authValue.tone.statusTone),
                finding: presentation.highestSeverity(for: grant.id) != nil
            ),
            notes: notes,
            runningText: isRunning ? String(localized: "Wird zurückgesetzt …") : nil
        )
    }

    private static func badges(_ grants: [PermissionGrant], presentation: PresentationSnapshot) -> [RecordBadge] {
        presentation.badges.badges(forAll: grants.map(\.id))
    }

    private static func appCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 App") : String(localized: "\(count) Apps")
    }
}

/// Was eine Berechtigung im Detail benennt: in der App-Ansicht den Dienst, in der Dienst-Ansicht die App.
enum GrantSubject {
    case service, app
}
