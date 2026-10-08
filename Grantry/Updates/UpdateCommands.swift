import AppKit
import ManagerKit
import SwiftUI

/// „Nach Updates suchen …“ im App-Menü, unter „Über Grantry“.
struct UpdateCommands: Commands {
    let updates: UpdateModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { Task { await UpdateAlert.checkAndShow(updates) } }
                .disabled(updates.isChecking)
        }
    }
}

/// Zeigt das Ergebnis einer manuellen Prüfung in einem Hinweisfenster; bei neuer Version mit „Laden …“.
@MainActor
enum UpdateAlert {
    static func checkAndShow(_ updates: UpdateModel) async {
        guard let outcome = await updates.checkNow() else { return }
        let alert = NSAlert()
        alert.informativeText = outcome.text
        if case .available = outcome {
            alert.messageText = UpdateTexts.availableTitle
            alert.addButton(withTitle: UpdateTexts.download)
            alert.addButton(withTitle: String(localized: "Später"))
        } else {
            alert.messageText = String(localized: "Nach Updates suchen")
            alert.addButton(withTitle: String(localized: "OK"))
        }
        NSApp.activate()
        let response = alert.runModal()
        if case .available(let item) = outcome, response == .alertFirstButtonReturn {
            updates.openDownload(item)
        }
    }
}
