import SwiftUI

/// „App entfernen …“ der ausgewählten App; gesetzt von der Liste des Bereichs „Apps“ (nur mit Fokus dort und ohne
/// offenes Blatt).
struct RemoveAppAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var removeSelectedApp: RemoveAppAction?
}

/// „Bearbeiten → App entfernen …“ (⌘⌫), nur aktiv bei ausgewählter App (Spec v3 §3, Einstiegspunkt 3). Öffnet nur das
/// Entfernen-Blatt; entfernt wird erst nach Bestätigung dort.
struct AppCommands: Commands {
    @FocusedValue(\.removeSelectedApp) private var removeSelectedApp

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("App entfernen …") { removeSelectedApp?.perform() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(removeSelectedApp == nil)
        }
    }
}

/// „Grantry › Grantry deinstallieren …“ (#115): öffnet das Entfernen-Blatt von Grantry selbst; deinstalliert wird erst
/// nach Bestätigung dort. Aktiv, sobald ein Scan Grantry gefunden hat.
struct UninstallCommands: Commands {
    let appModel: AppModel
    let navigator: MainWindowNavigator

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Grantry deinstallieren …") { navigator.showSelfUninstall() }
                .disabled(appModel.ownApp == nil)
        }
    }
}
