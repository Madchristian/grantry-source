import ManagerKit
import SwiftUI

/// „App entfernen …“ bzw. „Reste anzeigen“ (Spec v3 §3). Legt das `RemovalModel` einmal beim Erscheinen an – nicht bei
/// jeder Auswertung des Blatt-Inhalts (`State(initialValue:)` würde jedes Mal ein Modell erzeugen). Für Grantry selbst
/// zeigt das Blatt nach der Bestätigung Fortschritt und Bericht der Deinstallation (#143).
struct RemovalSheet: View {
    let request: RemovalRequest
    let appModel: AppModel
    @State private var model: RemovalModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let model {
            if model.isSelfUninstall, let progress = appModel.selfUninstall.progress {
                SelfUninstallProgressView(
                    presentation: SelfUninstallProgressPresentation(progress), canRetry: appModel.selfUninstall.canRetry,
                    retry: appModel.retryUninstall,
                    close: {
                        appModel.closeSelfUninstall()
                        dismiss()
                    }
                )
                .padding(20)
                .frame(width: RemovalSheetContent.width)
            } else {
                RemovalSheetContent(actions: appModel.actions, model: model, uninstallGrantry: appModel.uninstallGrantry)
            }
        } else {
            Color.clear
                .frame(width: RemovalSheetContent.width, height: 120)
                .onAppear {
                    model = RemovalModel(request: request, snapshot: appModel.monitoring.snapshot, scanner: appModel.leftovers,
                                         runningApps: appModel.runningApps)
                }
        }
    }
}

/// Auswahl und Bestätigung in einem Blatt; Return und Escape brechen ab, die Aktion läuft nur nach einem Klick
/// (`ConfirmationButtonRow`). Läuft die App, wird nur „Beenden“ angeboten; Homebrew-Casks zeigen einen Hinweis statt
/// einer Aktion, Grantry selbst „Grantry deinstallieren“ (#115).
private struct RemovalSheetContent: View {
    static let width: CGFloat = 600

    let actions: ActionRunner
    @Bindable var model: RemovalModel
    let uninstallGrantry: (SelfUninstallPlan) -> Void
    @Environment(\.dismiss) private var dismiss

    private var app: InstalledApp { model.app }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch model.route {
            case .grantryItself:
                InfoLabel(text: String(localized: "Grantry meldet den Hintergrunddienst und „Beim Anmelden starten“ ab, setzt die gewählten Berechtigungen zurück, legt die Auswahl in den Papierkorb und beendet sich. Für Einträge unter /Library fragt der Finder nach dem Passwort. Einmal gestartet, lässt sich der Vorgang nicht abbrechen; der Fortschritt erscheint hier."))
                removableContent
            case .homebrew(let command):
                HomebrewHint(command: command, mode: model.request.mode)
            case .otherGrantryCopy:
                InfoLabel(text: String(localized: "Weitere Kopie von Grantry – sie teilt Berechtigungen und Daten mit der laufenden Grantry. Grantry entfernt sie deshalb nicht; bitte im Finder in den Papierkorb legen."))
            case .removable:
                removableContent
            }
            buttons
        }
        .padding(20)
        .frame(width: Self.width)
        .task { model.startSearch() }
        .task { await model.watchRunningState() }
        .onDisappear { model.search.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIconView(app: app.identity, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.isSelfUninstall ? String(localized: "Grantry deinstallieren")
                     : model.request.mode == .uninstall
                     ? String(localized: "„\(app.name)“ entfernen") : String(localized: "Reste von „\(app.name)“"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                PathText(path: PathDisplay.abbreviatingHome(app.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Entfernbare App

    @ViewBuilder
    private var removableContent: some View {
        if model.isAppRunning { runningNotice }
        if !model.canSearch {
            InfoLabel(text: String(localized: "Die Reste-Suche ist erst nach dem ersten Scan möglich."))
        }
        SearchStatusView(search: model.search, searchingTitle: "Reste werden gesucht …", retry: model.startSearch)
        if let review = model.review {
            List {
                LeftoverSectionsList(sections: review.sections, selection: $model.selection)
                if !review.grants.isEmpty {
                    Section("Berechtigungen zurücksetzen") {
                        ForEach(review.grants) { grant in
                            SelectionToggleRow(grant: grant, note: review.note(for: grant.id), selection: $model.selection)
                        }
                    }
                }
                if !review.autostartItems.isEmpty {
                    Section("Autostart-Einträge entfernen") {
                        ForEach(review.autostartItems) { item in
                            SelectionToggleRow(autostartItem: item, note: review.note(for: item.id), selection: $model.selection)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220, idealHeight: 380)
            let notices = [review.sharedNotice, review.unreadableNote].compactMap(\.self)
            if !notices.isEmpty { NoticeList(notices: notices) }
            summary(review)
        }
    }

    private var runningNotice: some View {
        HStack(spacing: 8) {
            NoticeList(notices: [model.quitFailed
                ? String(localized: "„\(app.name)“ läuft und hat das Beenden abgelehnt – bitte selbst beenden.")
                : String(localized: "„\(app.name)“ läuft – zum Entfernen zuerst beenden.")])
            Button("Beenden", action: model.quitApp)
        }
    }

    private func summary(_ review: RemovalReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: review.summary(for: model.selection))
                .fontWeight(.medium)
            if let plan = model.plan, let note = ActionConfirmation.removal(plan).note {
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Knöpfe

    private var buttons: some View {
        ConfirmationButtonRow(
            cancelTitle: model.route == .removable || model.isSelfUninstall ? "Abbrechen" : "Schließen",
            confirm: model.isSelfUninstall ? selfUninstallAction : model.route == .removable ? confirmAction : nil,
            cancel: { dismiss() }
        )
    }

    private var confirmAction: ConfirmationButtonRow.Confirm {
        let title = model.plan.map { ActionConfirmation.removal($0).confirmTitle } ?? String(localized: "In den Papierkorb legen")
        return .init(title: title, isDestructive: true, isEnabled: model.canConfirm(actionsCanStart: actions.canStart)) {
            guard let plan = model.plan, model.canConfirm(actionsCanStart: actions.canStart) else { return }
            dismiss()
            Task { await actions.performRemoval(plan, context: .apps) }
        }
    }

    private var selfUninstallAction: ConfirmationButtonRow.Confirm {
        .init(title: String(localized: "Grantry deinstallieren"), isDestructive: true,
              isEnabled: model.canConfirm(actionsCanStart: actions.canStart)) {
            guard let plan = model.selfUninstallPlan, model.canConfirm(actionsCanStart: actions.canStart) else { return }
            // Das Blatt bleibt offen und zeigt den Fortschritt (#143).
            uninstallGrantry(plan)
        }
    }
}

/// Homebrew-Cask: Grantry entfernt die App nicht selbst, sondern zeigt den Befehl zum Kopieren (Spec v3 §3).
private struct HomebrewHint: View {
    let command: String
    let mode: RemovalRequest.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch mode {
            case .uninstall:
                Text("Mit Homebrew installiert. Entferne die App im Terminal:")
            case .leftovers:
                Text("Mit Homebrew installiert – solange Homebrew die App verwaltet, sucht Grantry keine Reste. Zum Entfernen im Terminal:")
            }
            HStack(spacing: 8) {
                Text(verbatim: command)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                CopyCommandButton(command: command)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            Text("Die Reste findet danach der Bereich „Aufräumen“.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
