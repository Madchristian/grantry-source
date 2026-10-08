import ManagerKit
import SwiftUI

/// Ein auswählbarer Eintrag beim Entfernen und Aufräumen: Kästchen, Titel, Angaben, Kennzeichen „Zuordnung unsicher“ (als Text,
/// nicht nur als Farbe) und Hinweis. Nicht veränderbare Einträge sind gesperrt und nennen den Grund.
struct SelectionToggleRow: View {
    let title: String
    var detail: String?
    var badge: String?
    /// Erklärung zum Kennzeichen (Tooltip).
    var badgeHelp: String?
    var note: String?
    var disabledReason: String?
    let accessibilityLabel: String
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: title))
                    if let badge {
                        Text(verbatim: badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PresentationTone.warning.color)
                            .help(badgeHelp.map { Text(verbatim: $0) } ?? Text(verbatim: badge))
                    }
                }
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note {
                    HintLabel(text: note, systemImage: PresentationTone.warning.systemImage, color: PresentationTone.warning.color)
                }
                if let disabledReason {
                    HintLabel(text: disabledReason, systemImage: "lock", color: .secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabledReason != nil)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }
}

extension SelectionToggleRow {
    private static let policy = ActionPolicy()

    /// Ein Rest; `kindTitle` nennt seine Art, wenn kein Abschnitt sie trägt (Aufräumen).
    init(row: LeftoverRow, kindTitle: String? = nil, selection: Binding<RemovalSelection>) {
        self.init(
            title: row.pathText,
            detail: [kindTitle, row.sizeText].compactMap(\.self).joined(separator: " · "),
            badge: row.isPreselected ? nil : row.confidenceText,
            badgeHelp: LeftoverRow.uncertainExplanation,
            note: row.note,
            accessibilityLabel: [kindTitle, row.accessibilityLabel].compactMap(\.self).joined(separator: ", "),
            isSelected: Binding(selection, id: row.id)
        )
    }

    /// Eine Berechtigung der App (zurücksetzen per `tccutil`, solange die App installiert ist); `note` z. B. bei weiteren
    /// Installationen derselben Bundle-ID (`RemovalReview.note(for:)`).
    init(grant: PermissionGrant, note: String? = nil, selection: Binding<RemovalSelection>) {
        let reason = Self.policy.availability(for: grant).readOnlyReason
        let state = grant.authValue.displayName.capitalizedFirst
        self.init(
            title: grant.serviceName, detail: state, note: note, disabledReason: reason,
            accessibilityLabel: [String(localized: "Berechtigung \(grant.serviceName)"), state,
                                 note.map { String(localized: "Hinweis: \($0)") }, reason]
                .compactMap(\.self).joined(separator: ", "),
            isSelected: Binding(selection, id: grant.id)
        )
    }

    /// Ein Autostart-Eintrag (entfernen mit Wiederherstellungsbeleg); `note` wie bei Berechtigungen.
    init(autostartItem item: AutostartItem, note: String? = nil, selection: Binding<RemovalSelection>) {
        let reason = Self.policy.availability(for: item).readOnlyReason
        let detail = item.owner?.displayName ?? item.program
        self.init(
            title: item.label, detail: detail, note: note, disabledReason: reason,
            accessibilityLabel: [String(localized: "Autostart-Eintrag \(item.label)"), detail,
                                 note.map { String(localized: "Hinweis: \($0)") }, reason]
                .compactMap(\.self).joined(separator: ", "),
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

/// Reste nach Art: je Art ein Abschnitt mit Summe.
struct LeftoverSectionsList: View {
    let sections: [LeftoverSection]
    @Binding var selection: RemovalSelection

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.rows) { row in
                    SelectionToggleRow(row: row, selection: $selection)
                }
            } header: {
                SectionHeader(title: section.title, trailing: section.sizeText)
            }
        }
    }
}

/// Abschnittskopf mit Angabe rechts (z. B. Summe der Größe).
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(verbatim: title)
            Spacer(minLength: 8)
            if let trailing {
                Text(verbatim: trailing).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
