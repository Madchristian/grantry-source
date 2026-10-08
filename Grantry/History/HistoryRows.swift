import ManagerKit
import SwiftUI

/// Eine Änderung im Verlauf; an Ereignissen mit Beleg zusätzlich „Wiederherstellen …“, bei geändertem Befehl dessen
/// Vorher/Nachher zum Aufklappen (#137).
struct HistoryEventRow: View {
    let event: HistoryEvent
    let restorable: RestorableChange?
    let actions: ActionRunner
    let restore: (RestorableChange) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ChangeRow(event: event)
                if let change = event.event.commandChange {
                    CommandChangeDisclosure(change: change)
                }
            }
            if let restorable {
                RestoreButton(change: restorable, actions: actions) { restore(restorable) }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(event.isRead ? nil : Color.accentColor.opacity(0.08))
    }
}

/// Beleg ohne geladenes Ereignis (Liste „Wiederherstellbar“): Label, Zeitpunkt der Änderung, Speicherort bzw. Tool.
struct RestorableChangeRow: View {
    let change: RestorableChange
    let actions: ActionRunner
    let restore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: change.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.everyMinute) { context in
                    Text(verbatim: "\(change.actionName) \(RelativeTime.text(for: change.changedAt, now: context.date)) · \(change.storageName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            RestoreButton(change: change, actions: actions, action: restore)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// „Wiederherstellen …“; während die Wiederherstellung dieses Belegs läuft, eine Fortschrittsanzeige.
private struct RestoreButton: View {
    let change: RestorableChange
    let actions: ActionRunner
    let action: () -> Void

    var body: some View {
        if actions.runningRecordID == change.id.uuidString {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Wird wiederhergestellt")
        } else {
            Button("Wiederherstellen …", action: action)
                .controlSize(.small)
                .disabled(!actions.canStart)
                .help(Text(verbatim: change.restoreHelp))
        }
    }
}

/// Ende der geladenen Seiten: ältere Änderungen nachladen.
struct LoadMoreRow: View {
    let isLoading: Bool
    let loadMore: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button("Ältere Änderungen laden", action: loadMore)
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .listRowSeparator(.hidden)
    }
}

extension RemovalReceipt {
    /// „Benutzer“ bzw. „System“ – wo die Sicherung liegt.
    var storageName: String {
        isPrivileged ? String(localized: "System") : String(localized: "Benutzer")
    }
}

extension RestorableChange {
    /// Ortsangabe der Zeile unter „Wiederherstellbar“. Autostart: wo die Sicherung liegt („Benutzer“/„System“).
    /// Agenten: wohin zurückgelegt wird – Tool und Bereich („Claude Code (Projekt web)“), nicht der Ort der Sicherung
    /// (die liegt immer in Grantrys eigener Ablage); der Name bleibt aus Rücksicht auf die Autostart-Zeilen.
    var storageName: String {
        switch self {
        case .autostart(let entry): entry.receipt.storageName
        case .agentConfig(let change): change.server.locationDescription
        }
    }
}
