import GrantryCharts
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

    /// Mitgebrachte Erweiterungen der App (TM-13.6); nur beim Entfernen, nicht bei „Reste anzeigen“.
    private var extensionNote: String? {
        request.mode == .uninstall ? appModel.presentation?.extensions.removalNote(forAppAt: request.app.path) : nil
    }

    var body: some View {
        if let model {
            if model.isSelfUninstall, let progress = appModel.selfUninstall.progress {
                SelfUninstallProgressView(
                    presentation: SelfUninstallProgressPresentation(progress), app: model.app.identity,
                    canRetry: appModel.selfUninstall.canRetry, retry: appModel.retryUninstall,
                    close: {
                        appModel.closeSelfUninstall()
                        dismiss()
                    }
                )
            } else {
                RemovalSheetContent(actions: appModel.actions, model: model, extensionNote: extensionNote,
                                    uninstallGrantry: appModel.uninstallGrantry)
            }
        } else {
            Color.clear
                .frame(width: RemovalSheetLayout.width, height: 120)
                .onAppear {
                    model = RemovalModel(request: request, snapshot: appModel.monitoring.snapshot, scanner: appModel.leftovers,
                                         runningApps: appModel.runningApps)
                }
        }
    }
}

/// Blatt im Lagebild (Spec 2026-11-10 § 11.4 f, `RemovalSheetBoard`): Peilkopf mit App-Symbol, Titel und Ort, Hinweise,
/// Panel mit Inhalt und Leiste. Teilen sich Auswahl und Fortschritt der Selbstdeinstallation.
struct AppRemovalBoard<Notes: View, Content: View, Bar: View>: View {
    let title: String
    let app: AppIdentity
    var panel: RemovalSheetLayout.Panel = .fitting
    @ViewBuilder let notes: Notes
    @ViewBuilder let content: Content
    @ViewBuilder let bar: Bar

    var body: some View {
        RemovalSheetBoard(title: title, path: PathDisplay.abbreviatingHome(app.path ?? ""), panel: panel) {
            AppIconView(app: app, size: InstrumentSize.shield)
        } notes: {
            notes
        } content: {
            content
        } bar: {
            bar
        }
    }
}

/// Inhalt ohne Liste im Panel (Suche, Hinweise, Homebrew-Befehl): untereinander mit Innenabstand.
struct RemovalPanelStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) { content }
            .padding(InstrumentSpacing.panel)
    }
}

/// Auswahl und Bestätigung in einem Blatt; Return und Escape brechen ab, die Aktion läuft nur nach einem Klick
/// (`ConfirmationButtonRow` in der Leiste unten). Läuft die App, wird nur „Beenden“ angeboten; Homebrew-Casks zeigen
/// einen Hinweis statt einer Aktion, Grantry selbst „Grantry deinstallieren“ (#115). Bringt die App Erweiterungen mit,
/// nennt ein Hinweis sie (TM-13.6).
private struct RemovalSheetContent: View {
    let actions: ActionRunner
    @Bindable var model: RemovalModel
    /// Systemerweiterungen, die mit der App gehen, und Erweiterungen, die bleiben; ändert den Ablauf nicht.
    let extensionNote: String?
    let uninstallGrantry: (SelfUninstallPlan) -> Void
    @Environment(\.dismiss) private var dismiss

    private var app: InstalledApp { model.app }
    private var removesItself: Bool { model.route == .removable || model.isSelfUninstall }

    var body: some View {
        AppRemovalBoard(title: title, app: app.identity, panel: model.review != nil ? .scrolling : .fitting) {
            notes
        } content: {
            content
        } bar: {
            InstrumentActionBar(scope: scope) {
                searchControl
            } trailing: {
                buttons
            }
        }
        .task { model.startSearch() }
        .task { await model.watchRunningState() }
        .onDisappear { model.search.cancel() }
    }

    private var title: String {
        model.isSelfUninstall ? String(localized: "Grantry deinstallieren")
            : model.request.mode == .uninstall
            ? String(localized: "„\(app.name)“ entfernen") : String(localized: "Reste von „\(app.name)“")
    }

    // MARK: - Hinweise unter dem Kopf

    @ViewBuilder
    private var notes: some View {
        switch model.route {
        case .grantryItself:
            InstrumentNote(String(localized: "Grantry meldet den Hintergrunddienst und „Beim Anmelden starten“ ab, setzt die gewählten Berechtigungen zurück, legt die Auswahl in den Papierkorb und beendet sich. Für Einträge unter /Library fragt der Finder nach dem Passwort. Einmal gestartet, lässt sich der Vorgang nicht abbrechen; der Fortschritt erscheint hier."))
            searchNotes
        case .removable:
            if model.isAppRunning { runningBanner }
            if let extensionNote {
                InstrumentNote(extensionNote)
            }
            searchNotes
        case .homebrew, .otherGrantryCopy:
            EmptyView()
        }
    }

    @ViewBuilder
    private var searchNotes: some View {
        if !model.canSearch {
            InstrumentNote(String(localized: "Die Reste-Suche ist erst nach dem ersten Scan möglich."))
        }
    }

    private var runningBanner: some View {
        InstrumentBanner(String(localized: "„\(app.name)“ läuft"),
                         message: model.quitFailed ? String(localized: "Hat das Beenden abgelehnt – bitte selbst beenden.")
                             : String(localized: "Zum Entfernen zuerst beenden."),
                         tone: .finding) {
            Button("Beenden", action: model.quitApp)
        }
    }

    // MARK: - Panel

    @ViewBuilder
    private var content: some View {
        switch model.route {
        case .grantryItself, .removable:
            findings
        case .homebrew(let command):
            RemovalPanelStack {
                HomebrewHint(command: command, mode: model.request.mode)
            }
        case .otherGrantryCopy:
            RemovalPanelStack {
                InstrumentNote(String(localized: "Weitere Kopie von Grantry – sie teilt Berechtigungen und Daten mit der laufenden Grantry. Grantry entfernt sie deshalb nicht; bitte im Finder in den Papierkorb legen."))
            }
        }
    }

    @ViewBuilder
    private var findings: some View {
        switch model.search.phase {
        case .searching:
            RemovalPanelStack {
                ProgressSpur(title: String(localized: "Reste werden gesucht"), detail: "", fraction: searchFraction,
                             tone: .info)
            }
        case .cancelled:
            RemovalPanelStack {
                InstrumentNote(String(localized: "Suche abgebrochen – es wird nichts angeboten."))
            }
        case .idle, .finished:
            if let review = model.review {
                RemovalFindings(review: review, selection: $model.selection, planNote: planNote)
            }
        }
    }

    /// Anteil der Suche, solange sie Schritte meldet; sonst leere Bahn (Dauer unbekannt).
    private var searchFraction: Double? {
        model.search.progress.current.flatMap { $0.isIndeterminate ? nil : $0.fraction }
    }

    /// Hinweise der Bestätigung (Wiederherstellen, nicht durchsuchte Orte) unter der Auswahl.
    private var planNote: String? {
        model.plan.flatMap { ActionConfirmation.removal($0).note }
    }

    // MARK: - Leiste

    private var scope: String {
        guard removesItself else { return String(localized: "Grantry entfernt diese App nicht selbst") }
        return model.review?.summary(for: model.selection) ?? String(localized: "Nichts ausgewählt")
    }

    /// Links in der Leiste: Suche abbrechen bzw. nach einem Abbruch erneut suchen.
    @ViewBuilder
    private var searchControl: some View {
        switch model.search.phase {
        case .searching:
            Button("Suche abbrechen", action: model.search.cancel)
        case .cancelled:
            Button("Erneut suchen", action: model.startSearch)
        case .idle, .finished:
            EmptyView()
        }
    }

    private var buttons: some View {
        ConfirmationButtonRow(
            cancelTitle: removesItself ? "Abbrechen" : "Schließen",
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

/// Reste nach Art, Berechtigungen und Autostart-Einträge der App als Gruppen mit Häkchenzeilen (lazy, rollt im Panel);
/// darunter Hinweise zur Auswahl und zur Bestätigung.
private struct RemovalFindings: View {
    let review: RemovalReview
    @Binding var selection: RemovalSelection
    let planNote: String?

    var body: some View {
        CleanupFindingList {
            LeftoverSectionsList(sections: review.sections, selection: $selection)
            if !review.grants.isEmpty {
                SelectionGroupHeader(title: String(localized: "Berechtigungen zurücksetzen"), count: review.grants.count)
                ForEach(review.grants) { grant in
                    SelectionToggleRow(grant: grant, note: review.note(for: grant.id), selection: $selection)
                }
            }
            if !review.autostartItems.isEmpty {
                SelectionGroupHeader(title: String(localized: "Autostart-Einträge entfernen"),
                                     count: review.autostartItems.count)
                ForEach(review.autostartItems) { item in
                    SelectionToggleRow(autostartItem: item, note: review.note(for: item.id), selection: $selection)
                }
            }
            if let sharedNotice = review.sharedNotice {
                InstrumentNote(sharedNotice)
            }
            if let unreadableNote = review.unreadableNote {
                InstrumentNote(unreadableNote, kind: .finding)
            }
            if let planNote {
                InstrumentNote(planNote)
            }
        }
    }
}

/// Homebrew-Cask: Grantry entfernt die App nicht selbst, sondern zeigt den Befehl zum Kopieren (Spec v3 §3).
private struct HomebrewHint: View {
    let command: String
    let mode: RemovalRequest.Mode

    var body: some View {
        DetailItem(InstrumentRowContent(symbol: "terminal", title: String(localized: "Mit Homebrew installiert"),
                                        detail: detail)) {
            DetailEntry(String(localized: "Befehl"), value: command, isCode: true)
        } actions: {
            CopyCommandButton(command: command)
        }
        InstrumentNote(String(localized: "Die Reste findet danach der Bereich „Aufräumen“."))
    }

    private var detail: String {
        switch mode {
        case .uninstall:
            String(localized: "Entferne die App im Terminal.")
        case .leftovers:
            String(localized: "Solange Homebrew die App verwaltet, sucht Grantry keine Reste. Zum Entfernen im Terminal:")
        }
    }
}
