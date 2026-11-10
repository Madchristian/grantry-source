import ManagerKit
import SwiftUI

/// „Erweiterungen ohne App“ über der Fundliste in „Aufräumen › App-Reste“ (TM-13.6, Spec 2026-11-08 § 5.2): aus dem
/// Inventar, daher auch ohne Suche. Je Erweiterung ein Hinweis zur Deinstallation und die Aktionen aus dem Bereich
/// „Erweiterungen“ – für Plug-ins „In den Papierkorb …“ nach Bestätigung über den Finder; Kernel- und Systemerweiterungen
/// entfernt Grantry nicht selbst. Höchstens `maximumRows` Zeilen, der Rest im Bereich „Erweiterungen“.
struct ExtensionLeftoversBox: View {
    static let maximumRows = 4

    let leftovers: [ExtensionLeftover]
    let appModel: AppModel
    @Environment(MainWindowModel.self) private var window
    @State private var trash = ServicePluginTrashFlow()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(leftovers.prefix(Self.maximumRows)) { leftover in
                ExtensionLeftoverRow(leftover: leftover, appModel: appModel, trash: trash)
            }
            if leftovers.count > Self.maximumRows {
                Button("Alle im Bereich „Erweiterungen“ zeigen") { window.show(.extensions) }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .bottom], 12)
        .servicePluginTrashDialogs(trash, appModel: appModel)
    }

    private var title: String {
        leftovers.count == 1 ? String(localized: "1 Erweiterung ohne App")
            : String(localized: "\(leftovers.count) Erweiterungen ohne App")
    }
}

/// Eine Erweiterung ohne App: Name, Art und Zustand, Hinweis und Aktionen; der Name springt in den Bereich.
private struct ExtensionLeftoverRow: View {
    let leftover: ExtensionLeftover
    let appModel: AppModel
    let trash: ServicePluginTrashFlow
    @Environment(MainWindowModel.self) private var window

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: leftover.reference.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: leftover.reference.title)
                        .fontWeight(.medium)
                    Text(verbatim: leftover.reference.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(verbatim: leftover.note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 12) {
                    Button("In „Erweiterungen“ zeigen") { window.show(leftover.reference) }
                    ForEach(leftover.actions, id: \.self) { action in
                        ExtensionActionButton(action: action, record: leftover.reference.record, appModel: appModel,
                                              trash: trash)
                    }
                }
                .buttonStyle(.link)
            }
        }
    }
}
