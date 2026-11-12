import GrantryCharts
import ManagerKit
import SwiftUI

/// Vollständige Lizenztexte der eingebundenen Fremdkomponenten aus dem App-Paket (#519), unverändert und auswählbar.
/// Fehlt ein Text im Paket, steht dort ein Fehler statt einer leeren Liste.
struct ThirdPartyLicensesView: View {
    /// Einmal je Start geladen: Die Texte ändern sich erst mit einem neuen App-Paket.
    static let bundled: Result<[ThirdPartyLicense], any Error> = Result {
        guard let resources = Bundle.main.resourceURL else { throw ThirdPartyNotices.LoadError.missingManifest }
        return try ThirdPartyNotices.load(fromResources: resources)
    }

    var licenses: Result<[ThirdPartyLicense], any Error> = Self.bundled
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            Text("Drittanbieter-Lizenzen").font(InstrumentFont.verdict)
            switch licenses {
            case .success(let licenses):
                Text("Grantry enthält die folgenden Komponenten. Ihre Lizenzen verlangen, dass dieser Text jeder Kopie beiliegt.")
                    .font(InstrumentFont.body)
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.empty) {
                        ForEach(licenses) { ThirdPartyLicenseBlock(license: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("thirdPartyLicenseTexts")
            case .failure:
                InstrumentNote(String(localized: "Die Lizenztexte fehlen im App-Paket. Bitte Grantry neu laden und installieren."),
                               kind: .critical)
            }
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(InstrumentSpacing.empty)
        .frame(width: 620, height: 520)
    }
}

/// Eine Komponente: Name, Version, Projektseite und der Lizenztext in Festbreitenschrift wie im Original.
private struct ThirdPartyLicenseBlock: View {
    let license: ThirdPartyLicense

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(license.notice.name) \(license.notice.version)").font(InstrumentFont.title)
                Spacer()
                Link("Projektseite", destination: license.notice.projectURL)
            }
            Text(verbatim: license.text)
                .font(InstrumentFont.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Lizenzen") {
    ThirdPartyLicensesView(licenses: .success([ThirdPartyLicense(
        notice: ThirdPartyNotice(name: "Sparkle", version: "2.10.0", revision: "eef1a539",
                                 projectURL: URL(string: "https://github.com/sparkle-project/Sparkle")!,
                                 licenseFile: "Sparkle-LICENSE.txt"),
        text: "Copyright (c) 2006-2013 Andy Matuschak.\n\nPermission is hereby granted, free of charge, …")]))
}

#Preview("Fehlt") {
    ThirdPartyLicensesView(licenses: .failure(ThirdPartyNotices.LoadError.missingManifest))
}
