import GrantryCharts
import ManagerKit
import SwiftUI

/// Fortschritt und Bericht von „Grantry deinstallieren …“ im Entfernen-Blatt (#143) im Lagebild (§ 11.4 f): Kopf wie bei
/// der Auswahl, Ergebnis als Banner, Schritte mit Zustandschip (Text, nicht nur Farbe), Hinweis zum laufenden Schritt,
/// unten die Leiste mit den nächsten Schritten und ggf. „Erneut versuchen“. Während des Ablaufs gibt es bewusst keinen
/// Abbrechen-Knopf – gesendete Aufträge an Finder bzw. macOS laufen weiter (`SelfUninstallProgressPresentation`).
/// VoiceOver sagt jeden begonnenen Schritt und das Ergebnis an.
struct SelfUninstallProgressView: View {
    let presentation: SelfUninstallProgressPresentation
    /// Grantry selbst (Symbol und Ort im Kopf).
    let app: AppIdentity
    /// „Erneut versuchen“ ist jetzt möglich (`SelfUninstallFlow.canRetry` – nichts anderes läuft).
    let canRetry: Bool
    let retry: () -> Void
    /// „Schließen“ bzw. – liegt Grantry im Papierkorb – „Beenden“.
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        AppRemovalBoard(title: presentation.title, app: app) {
            if let outcome = presentation.outcome {
                InstrumentBanner(outcome.text, message: outcome.details.map { "• " + $0 }.joined(separator: "\n"),
                                 tone: outcome.tone.statusTone)
                    // Einzelzeilen nennen manuelle Wege (etwa den tccutil-Befehl) und bleiben kopierbar.
                    .textSelection(.enabled)
            }
        } content: {
            RemovalPanelStack {
                ProcedureStepList(steps: presentation.rows.map(\.procedureStep))
                if let hint = presentation.runningHint { InstrumentNote(hint) }
                ForEach(presentation.notes, id: \.self) { InstrumentNote($0) }
            }
        } bar: {
            InstrumentActionBar(scope: presentation.isRunning ? String(localized: "Läuft – lässt sich nicht abbrechen") : "") {
                settingsButtons
            } trailing: {
                buttons
            }
        }
        .interactiveDismissDisabled(presentation.isRunning)
        .onChange(of: presentation.announcement, initial: true) { _, announcement in
            if let announcement { AccessibilityNotification.Announcement(announcement).post() }
        }
    }

    @ViewBuilder
    private var settingsButtons: some View {
        if !presentation.isRunning {
            if let url = presentation.outcome?.settingsURL {
                Button("In Systemeinstellungen öffnen") { openURL(url) }
            }
            if presentation.offersLoginItemsSettings {
                Button("Anmeldeobjekte öffnen") { LaunchAtLogin.openSettings() }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if !presentation.isRunning {
            // Liegt Grantry im Papierkorb, beendet „Beenden“ die App – auch neben „Erneut versuchen“, wenn ein Dienst
            // noch angemeldet ist (#143).
            Button(presentation.quitsApp ? LocalizedStringKey("Beenden") : "Schließen", role: .cancel, action: close)
                .keyboardShortcut(presentation.offersRetry ? .cancelAction : .defaultAction)
            if presentation.offersRetry {
                Button("Erneut versuchen", action: retry)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRetry)
            }
        }
    }
}

extension SelfUninstallProgressPresentation.StepRow {
    /// Schritt mit Zustandschip; der laufende im Ton info mit Fortschritt, sonst im Ton des Zustands.
    var procedureStep: ProcedureStep {
        ProcedureStep(id: String(describing: step), title: title,
                      state: StatusItem(statusText, tone: state == .running ? .info : tone.statusTone),
                      isRunning: state == .running)
    }
}

#if DEBUG
private struct SelfUninstallProgressPreview: View {
    let progress: SelfUninstallProgress

    var body: some View {
        SelfUninstallProgressView(
            presentation: SelfUninstallProgressPresentation(progress),
            app: AppIdentity(bundleID: GrantryIdentity.appBundleID, path: "/Applications/Grantry.app",
                             displayName: "Grantry", signing: SigningInfo(kind: .developerID, teamID: nil, isNotarized: true),
                             presence: .present),
            canRetry: true, retry: {}, close: {}
        )
    }
}

#Preview("Deinstallation, Papierkorb läuft") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.trashing)
}

#Preview("Deinstallation, Passwortabfrage abgebrochen") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.passwordCancelled)
}

#Preview("Deinstallation, Abmeldung gescheitert") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.helperFailed)
}

#Preview("Deinstallation, Grantry im Papierkorb, Dienst noch angemeldet") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.removedButHelperRegistered)
}

#Preview("Deinstallation abgeschlossen") {
    SelfUninstallProgressPreview(progress: SelfUninstallPreviewData.removed)
}
#endif
