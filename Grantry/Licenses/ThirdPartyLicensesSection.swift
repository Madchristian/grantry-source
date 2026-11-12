import GrantryCharts
import SwiftUI

/// Gruppe „Lizenzen“ am Ende von Einstellungen › Allgemein (Spec 2026-11-10 § 11.5 a): Hinweis auf die eingebundenen
/// Fremdkomponenten und Zugang zu ihren Lizenztexten (#519).
struct ThirdPartyLicensesSection: View {
    @State private var isPresented = false

    var body: some View {
        SettingsPanel(String(localized: "Lizenzen"), detail: String(localized: "Komponenten anderer Anbieter")) {
            SettingRow(String(localized: "Drittanbieter-Lizenzen"),
                       note: String(localized: "Lizenztexte der Komponenten anderer Anbieter, die Grantry enthält."),
                       labelsControl: false) {
                Button("Lizenzen anzeigen …") { isPresented = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("showThirdPartyLicenses")
            }
        }
        .sheet(isPresented: $isPresented) { ThirdPartyLicensesView() }
    }
}
