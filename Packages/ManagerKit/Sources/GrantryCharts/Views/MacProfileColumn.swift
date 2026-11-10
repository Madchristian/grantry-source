import SwiftUI

/// Inhalt des Panels „Steckbrief“ (TM-16.3, Spec 2026-11-08 § 5.5) als fertige Texte; die Darstellung in ManagerKit
/// (`MacProfilePresentation`) rechnet. Die Seriennummer gehört nicht dazu – sie liegt nur im Zustand der Ansicht.
public struct MacProfileContent: Equatable, Sendable {
    /// Marketingname in `font.display`.
    public var name: String
    /// Detail im Peilkopf, etwa die Modellkennung.
    public var detail: String
    /// Messfelder (Chip, Speicher, macOS, Firmware, Laufzeit); fehlende Werte als „–“.
    public var fields: [MacProfileField]

    public init(name: String, detail: String, fields: [MacProfileField]) {
        self.name = name
        self.detail = detail
        self.fields = fields
    }
}

public struct MacProfileField: Hashable, Sendable {
    public let title: String
    public let value: String

    public init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
}

/// Eine Sprungzeile unter dem Steckbrief: Datenträger, Akku oder Netz mit Zustand in einem Satz und Sprung in den Bereich.
public struct MacLinkContent: Identifiable, Hashable, Sendable {
    public let id: String
    public let symbol: String
    public let title: String
    public let summary: String
    public let status: StatusItem?

    public init(id: String, symbol: String, title: String, summary: String, status: StatusItem? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.summary = summary
        self.status = status
    }

    /// VoiceOver: „Titel: Zustand. Satz“.
    var accessibilityLabel: String {
        status.map { "\(title): \($0.text). \(summary)" } ?? "\(title): \(summary)"
    }
}

/// Seriennummer im Steckbrief: verdeckt die Punkte, eingeblendet der Klartext (Spec § 4.5, O6).
public struct SecretValue: Equatable, Sendable {
    public let text: String
    public let isRevealed: Bool
    public let isBusy: Bool

    public init(text: String, isRevealed: Bool, isBusy: Bool = false) {
        self.text = text
        self.isRevealed = isRevealed
        self.isBusy = isBusy
    }
}

/// Linke Spalte des Bereichs „Sicherheit“ (Spec 2026-11-08 § 5.5, Standard §3.13): Panel „Steckbrief“ mit dem Namen in
/// `font.display`, Messfeldern und der verdeckten Seriennummer, darunter die Sprungzeilen. Ohne Sprungzeilen fehlt deren
/// Panel. Statisch: nichts misst oder zeichnet im Takt.
public struct MacProfileColumn: View {
    let profile: MacProfileContent
    let serial: SecretValue
    let links: [MacLinkContent]
    let toggleSerial: () -> Void
    let open: (MacLinkContent.ID) -> Void

    public init(profile: MacProfileContent, serial: SecretValue, links: [MacLinkContent],
                toggleSerial: @escaping () -> Void, open: @escaping (MacLinkContent.ID) -> Void) {
        self.profile = profile
        self.serial = serial
        self.links = links
        self.toggleSerial = toggleSerial
        self.open = open
    }

    public var body: some View {
        VStack(spacing: InstrumentSpacing.panel) {
            MacProfilePanel(profile: profile, serial: serial, toggleSerial: toggleSerial)
            if !links.isEmpty {
                MacLinksPanel(links: links, open: open)
            }
        }
    }
}

/// Platzhalter des Steckbriefs, solange er gelesen wird (#479): dasselbe Panel mit Peilkopf, statt der Felder ein
/// Fortschrittszeichen.
public struct MacProfileLoadingPanel: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Steckbrief"))
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Wird gelesen"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

private struct MacProfilePanel: View {
    let profile: MacProfileContent
    let serial: SecretValue
    let toggleSerial: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Steckbrief"), detail: profile.detail)
            Text(verbatim: profile.name)
                .font(InstrumentFont.display)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("macProfileName")
            MeasureFieldGrid(count: profile.fields.count + 1) {
                ForEach(profile.fields, id: \.title) { field in
                    MeasureField(title: field.title, value: field.value)
                }
                SecretMeasureField(title: String(localized: "Seriennummer"), value: serial.text,
                                   isRevealed: serial.isRevealed, isBusy: serial.isBusy, identifier: "serialNumber",
                                   toggle: toggleSerial)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}

/// Panel mit den Sprungzeilen: Peilkopf ohne Ring, je Zeile ein Knopf in den jeweiligen Bereich.
private struct MacLinksPanel: View {
    let links: [MacLinkContent]
    let open: (MacLinkContent.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Mehr zu diesem Mac"), detail: String(localized: "Sprung in den jeweiligen Bereich"))
            VStack(spacing: InstrumentSpacing.stack) {
                ForEach(links) { link in
                    Button { open(link.id) } label: {
                        InstrumentRowHead(symbol: link.symbol, title: link.title, reason: link.summary,
                                          status: link.status, accessory: .jump)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, InstrumentSpacing.group)
                    .padding(.vertical, InstrumentSpacing.item)
                    .instrumentRowBackground(isSelected: false)
                    .accessibilityLabel(Text(verbatim: link.accessibilityLabel))
                    .accessibilityHint(Text("Öffnet den Bereich."))
                    .accessibilityIdentifier("macLink.\(link.id)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentPanel()
    }
}
