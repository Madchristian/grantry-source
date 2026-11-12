import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI
import UniformTypeIdentifiers

/// Knöpfe zur Konfigurationsdatei am Ende der Gruppe „Konfiguration“ im Detail (LB-2.4, #541); Pfad und
/// Geltungsbereich stehen als Angaben darüber.
struct ConfigFileControls: View {
    /// Pfad wie in der Konfiguration (auch mit `~`).
    let path: String

    var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            ConfigFileButtons(path: path)
        }
        .controlSize(.small)
    }
}

/// „Im Finder zeigen“ und „Öffnen“ für eine Konfigurationsdatei – im Detail und im Kontextmenü der Zeilen.
///
/// „Öffnen“ startet nie die Standard-App der Datei: Nur was `ConfigFileOpening` freigibt (reguläre JSON-/TOML-Datei,
/// bei Symlinks das Ziel), öffnet Grantry im Editor für JSON bzw. Text – sonst ist der Knopf deaktiviert. Die Prüfung
/// läuft beim Klick erneut, falls die Datei inzwischen getauscht wurde. Liegt die Datei auf einem Netzlaufwerk, prüft
/// erst der Klick (`ConfigFileOpening.verdictIfLocal`) – ein hängender Server hielte sonst die Oberfläche an.
struct ConfigFileButtons: View {
    /// Pfad wie in der Konfiguration (auch mit `~`).
    let path: String

    var body: some View {
        let verdict = ConfigFileOpening.verdictIfLocal(for: path)
        Button("Im Finder zeigen") {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigFileOpening.fileURL(for: path)])
        }
        Button("Öffnen") { open() }
            .disabled(verdict.map(\.isOpenable) == false)
            .help(verdict?.help ?? "Öffnet die Datei im Editor, wenn sie eine JSON- oder TOML-Datei ist.")
    }

    private func open() {
        guard case .openable(let url) = ConfigFileOpening.verdict(for: path) else {
            NSSound.beep()
            return
        }
        let type: UTType = url.pathExtension.lowercased() == "toml" ? .plainText : .json
        let editor = NSWorkspace.shared.urlForApplication(toOpen: type)
            ?? URL(filePath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}

private extension ConfigFileOpening.Verdict {
    var isOpenable: Bool {
        if case .openable = self { true } else { false }
    }

    var help: LocalizedStringKey {
        switch self {
        case .openable: "Öffnet die Datei im Editor."
        case .missing: "Die Datei gibt es nicht mehr."
        case .notEditable: "Grantry öffnet nur JSON- und TOML-Dateien, keine anderen Dateiarten."
        }
    }
}
