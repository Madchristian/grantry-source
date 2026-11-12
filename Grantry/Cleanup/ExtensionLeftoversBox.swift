import GrantryCharts
import ManagerKit
import SwiftUI

/// „Erweiterungen ohne App“ als erste Gruppe im Fund-Panel von „Aufräumen › App-Reste“ (TM-13.6, Spec 2026-11-08 § 5.2;
/// Lagebild LB-4.2, #548): aus dem Inventar, daher auch ohne Suche. Je Erweiterung ein Eintrag auf der Mulde mit
/// Befund-Punkt, Hinweis zur Deinstallation und den Aktionen aus dem Bereich „Erweiterungen“ – für Plug-ins „In den
/// Papierkorb …“ nach Bestätigung über den Finder; Kernel- und Systemerweiterungen entfernt Grantry nicht selbst.
/// Höchstens `maximumRows` Einträge, der Rest im Bereich „Erweiterungen“.
struct ExtensionLeftoversBox: View {
    static let maximumRows = 4

    let leftovers: [ExtensionLeftover]
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var trash = ServicePluginTrashFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
            SelectionGroupHeader(title: String(localized: "Erweiterungen ohne App"), count: leftovers.count,
                                 finding: true)
            ForEach(leftovers.prefix(Self.maximumRows)) { leftover in
                DetailItem(LeftoversBoardMapping.extensionContent(leftover)) {
                    InstrumentNote(leftover.note, kind: .finding)
                } actions: {
                    Button("In „Erweiterungen“ zeigen") { window.show(leftover.reference) }
                    ForEach(leftover.actions, id: \.self) { action in
                        ExtensionActionButton(action: action, record: leftover.reference.record, appModel: appModel,
                                              trash: trash)
                    }
                }
            }
            if leftovers.count > Self.maximumRows {
                Button("Alle im Bereich „Erweiterungen“ zeigen") { window.show(.extensions) }
                    .buttonStyle(.link)
                    .font(InstrumentFont.label)
                    .padding(.horizontal, InstrumentSpacing.group)
            }
        }
        .servicePluginTrashDialogs(trash, appModel: appModel)
    }
}
