import GrantryCharts
import ManagerKit
import SwiftUI

/// Ein auswählbarer Eintrag beim Entfernen und Aufräumen als Häkchenzeile im Lagebild (`SelectionCheckRow`, Spec
/// §11.1 d): Häkchen im Grantry-Verlauf, Name und Ort, Kennzeichen „Zuordnung unsicher“ als Chip im Ton info (Text, nicht
/// nur Farbe; Bernstein nur für Befunde, § 11.4 b), rechts die Größe, darunter ein Hinweis. Nicht veränderbare Einträge
/// sind gesperrt und nennen den Grund. Der Zustand kommt gebunden herein; die Vorauswahl bleibt Sache des Modells.
struct SelectionToggleRow: View {
    let title: String
    var detail = ""
    var size = ""
    var badge: String?
    /// Erklärung zum Kennzeichen (Tooltip).
    var badgeHelp: String?
    var note: String?
    var disabledReason: String?
    @Binding var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            // „Zuordnung unsicher“ im Ton info: Bernstein bleibt Befunden vorbehalten (Spec 2026-11-10 § 11.4 b).
            SelectionCheckRow(title, detail: detail, size: size, isOn: $isSelected,
                              hint: badge.map { StatusItem($0, tone: .info) }, lockedReason: disabledReason)
                .help(Text(verbatim: badge.map { badgeHelp ?? $0 } ?? title))
            if let note {
                InstrumentNote(note, kind: .finding)
                    .padding(.leading, Self.noteIndent)
            }
        }
    }

    /// Hinweis bündig mit dem Namen: Innenabstand, Häkchen und Abstand der `SelectionCheckRow`.
    private static let noteIndent = InstrumentSpacing.group + InstrumentSize.disclosure + InstrumentSpacing.cell
}

extension SelectionToggleRow {
    private static let policy = ActionPolicy()

    /// Ein Rest: Dateiname und Pfad, Größe rechts; trägt kein Abschnitt die Art (Aufräumen), steht sie als Name.
    init(row: LeftoverRow, kindTitle: String? = nil, selection: Binding<RemovalSelection>) {
        self.init(
            title: kindTitle ?? (row.pathText as NSString).lastPathComponent,
            detail: row.pathText,
            size: row.sizeText,
            badge: row.isPreselected ? nil : row.confidenceText,
            badgeHelp: LeftoverRow.uncertainExplanation,
            note: row.note,
            isSelected: Binding(selection, id: row.id)
        )
    }

    /// Eine Berechtigung der App (zurücksetzen per `tccutil`, solange die App installiert ist); `note` z. B. bei weiteren
    /// Installationen derselben Bundle-ID (`RemovalReview.note(for:)`).
    init(grant: PermissionGrant, note: String? = nil, selection: Binding<RemovalSelection>) {
        self.init(
            title: grant.serviceName, detail: grant.authValue.displayName.capitalizedFirst, note: note,
            disabledReason: Self.policy.availability(for: grant).readOnlyReason,
            isSelected: Binding(selection, id: grant.id)
        )
    }

    /// Ein Autostart-Eintrag (entfernen mit Wiederherstellungsbeleg); `note` wie bei Berechtigungen.
    init(autostartItem item: AutostartItem, note: String? = nil, selection: Binding<RemovalSelection>) {
        self.init(
            title: item.label, detail: item.owner?.displayName ?? item.program ?? "", note: note,
            disabledReason: Self.policy.availability(for: item).readOnlyReason,
            isSelected: Binding(selection, id: item.id)
        )
    }
}

extension ActionAvailability {
    /// Grund, warum der Eintrag nur lesbar ist; `nil`, wenn die Aktion angeboten wird.
    var readOnlyReason: String? {
        switch self {
        case .available: nil
        case .readOnly(let reason): reason.description
        }
    }
}

extension Binding where Value == Bool {
    /// Auswahl eines Eintrags (Kandidaten-Pfad, `PermissionGrant.id`, `AutostartItem.id`) in einer `RemovalSelection`.
    init(_ selection: Binding<RemovalSelection>, id: String) {
        self.init(get: { selection.wrappedValue.contains(id) }, set: { selection.wrappedValue.set(id, selected: $0) })
    }
}

/// Reste nach Art: je Art ein Gruppenkopf mit Anzahl und Summe, darunter die Häkchenzeilen (Blatt „App entfernen“).
struct LeftoverSectionsList: View {
    let sections: [LeftoverSection]
    @Binding var selection: RemovalSelection

    var body: some View {
        ForEach(sections) { section in
            SelectionGroupHeader(title: section.title, count: section.rows.count, size: section.sizeText)
            ForEach(section.rows) { row in
                SelectionToggleRow(row: row, selection: $selection)
            }
        }
    }
}
