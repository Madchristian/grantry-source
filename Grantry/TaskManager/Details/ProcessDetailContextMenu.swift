import AppKit
import ManagerKit
import SwiftUI

/// Kontextmenü einer Zeile im Tab „Details“ (Spec §2): „Im Finder zeigen“ nur mit Pfad (eigene Prozesse), „Beenden“ und
/// „Sofort beenden“ über denselben Ablauf wie ⌫/⌥⌫ (`TaskTerminationFlow`, Bestätigung). Prozesse anderer Benutzer:
/// gesperrt mit Hinweis auf den Tab „Prozesse“, der sie über den Helper beendet (TM9).
struct ProcessDetailContextMenu: View {
    let row: ProcessDetailRow
    let canTerminate: Bool
    let prepare: (_ candidate: TaskTerminationCandidate, _ force: Bool) -> Void

    var body: some View {
        Button("Im Finder zeigen", systemImage: "folder") {
            if let path = row.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        .disabled(row.path == nil)
        Divider()
        Button("Beenden", systemImage: "xmark.circle") { row.terminationCandidate.map { prepare($0, false) } }
            .disabled(row.terminationCandidate == nil || !canTerminate)
        Button("Sofort beenden", systemImage: "bolt.circle") { row.terminationCandidate.map { prepare($0, true) } }
            .disabled(row.terminationCandidate == nil || !canTerminate)
        if let note = row.terminationNote {
            Text(note)
        }
    }
}

/// Ein-/Ausblenden der Spalten – im Kontextmenü der Spaltenköpfe und im Menü „Spalten“ der Symbolleiste.
struct ProcessDetailColumnToggles: View {
    let columns: ProcessDetailColumns
    let toggle: (ProcessDetailColumn) -> Void

    var body: some View {
        ForEach(ProcessDetailColumn.allCases.filter(\.isHideable)) { column in
            Toggle(column.title, isOn: Binding(get: { columns.contains(column) }, set: { _ in toggle(column) }))
        }
    }
}

/// Symbolleiste des Tabs „Details“: Prozessbaum und Spaltenwahl. Hängt nur an diesen beiden Einstellungen; der Tab setzt
/// sie außerhalb seines Teils, der je Messtakt neu ausgewertet wird (#489), sonst glich AppKit die Symbolleiste je Takt ab.
struct ProcessDetailToolbar: ToolbarContent {
    @Binding var showsTree: Bool
    @Binding var columns: ProcessDetailColumns

    var body: some ToolbarContent {
        ToolbarItem {
            Toggle("Prozessbaum", systemImage: "list.bullet.indent", isOn: $showsTree)
                .help("Eltern- und Kindprozesse eingerückt zeigen (← zuklappen, → aufklappen)")
        }
        ToolbarItem {
            Menu("Spalten", systemImage: "tablecells") {
                ProcessDetailColumnToggles(columns: columns) { columns.toggle($0) }
            }
            .help("Spalten ein- oder ausblenden")
        }
    }
}
