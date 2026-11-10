import SwiftUI
@testable import GrantryCharts

/// Bereich „Sicherheit“ im Lagebild mit festen Beispieldaten (TM-16.2, #407; TM-16.3, #408): Lagezeile, links Steckbrief
/// und Sprungzeilen, rechts Panel „Schutz“ wie in `SecurityView`, Texte und Zählung wie aus `SecurityOverview` (ManagerKit,
/// `SecurityVerdictTests`) und `MacProfilePresentation`. Fünf Lagen: alles in Ordnung, ein Punkt offen, kritisch (Mac ohne
/// Akku, SMART-Fehler), ohne Helper (dazu XProtect nicht prüfbar, fehlende Werte, ohne Datenträger und Netz) und ein
/// leerer Steckbrief (TM-16.5, #410: nichts lesbar, keine Sprungzeilen, nichts gewählt). Die Seriennummer ist immer
/// verdeckt – sie steht in keiner Referenz.
@MainActor
extension SnapshotGallery {
    enum SecurityScene: String, CaseIterable, Sendable {
        case protected = "geschuetzt"
        case oneOpen = "ein-punkt-offen"
        case critical = "kritisch"
        case withoutHelper = "ohne-helper"
        case emptyProfile = "steckbrief-leer"
    }

    static let securitySize = CGSize(width: 1180, height: 760)
    /// Die Seriennummer in allen Lagen: verdeckt, nie ein Klartext (Spec § 4.5).
    static let securitySerial = SecretValue(text: "••••••", isRevealed: false)

    static func security(_ scene: SecurityScene) -> some View {
        SecurityBoardSample(scene: scene)
    }
}

private struct SecurityBoardSample: View {
    let scene: SnapshotGallery.SecurityScene

    var body: some View {
        let verdict = Self.verdict(scene)
        let checks = Self.checks(scene)
        let open = checks.filter { [.finding, .critical].contains($0.status.tone) }.count
        let good = checks.filter { $0.status.tone == .positive }.count
        let unchecked = checks.filter { $0.status.text == "Nicht prüfbar" }.count
        let detail = "\(good) von \(checks.count) in Ordnung" + (unchecked > 0 ? " · \(unchecked) nicht prüfbar" : "")
        VStack(spacing: InstrumentSpacing.panel) {
            VerdictBar(verdict: verdict.title, reason: verdict.reason, finding: open > 0, items: verdict.items,
                       facts: scene == .withoutHelper ? "10 Prüfungen · Helper nicht bereit" : "10 Prüfungen · Helper bereit")
            InstrumentSideColumnLayout.profileAndChecks {
                MacProfileColumn(profile: Self.profile(scene), serial: SnapshotGallery.securitySerial,
                                 links: Self.links(scene), toggleSerial: {}, open: { _ in })
                CheckPanel("Schutz", detail: detail, value: open > 0 ? "\(open) offen" : "",
                           finding: open > 0,
                           note: scene == .withoutHelper
                               ? "Zum Einschalten von Schutzfunktionen wird der Helper benötigt (Einstellungen)." : nil,
                           items: checks, selection: .constant(Self.selection(scene))) { item in
                    SecurityOffersSample(offers: Self.offers(item.id, scene: scene), isEnabled: scene != .withoutHelper)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(InstrumentSpacing.page)
        .instrumentBackground()
    }

    static func verdict(_ scene: SnapshotGallery.SecurityScene) -> (title: String, reason: String, items: [StatusItem]) {
        let fileVault = StatusItem("FileVault an", tone: .positive)
        let sip = StatusItem("SIP aktiv", tone: .positive)
        return switch scene {
        case .protected, .emptyProfile:
            ("Geschützt", "Alle 10 Prüfungen sind in Ordnung.",
             [fileVault, StatusItem("Firewall an", tone: .positive), sip])
        case .oneOpen:
            ("1 Punkt offen", "Firewall an, Tarnmodus aus – der Mac antwortet auf Anfragen wie Ping.",
             [StatusItem("Tarnmodus aus", tone: .finding), fileVault, sip])
        case .critical:
            ("Kritisch: SIP aus", "Der Systemintegritätsschutz ist ausgeschaltet.",
             [StatusItem("SIP aus", tone: .critical), StatusItem("2 Updates offen", tone: .finding), fileVault])
        case .withoutHelper:
            ("Kritisch: Firewall aus", "Die Firewall ist ausgeschaltet.",
             [StatusItem("Firewall aus", tone: .critical), StatusItem("XProtect nicht prüfbar", tone: .neutral),
              fileVault])
        }
    }

    static func profile(_ scene: SnapshotGallery.SecurityScene) -> MacProfileContent {
        let uptime = MacProfileField("Laufzeit", "3:04:12:55")
        return switch scene {
        case .protected, .oneOpen:
            MacProfileContent(name: "MacBook Pro (14-inch, Nov 2024)", detail: "Mac16,6", fields: [
                MacProfileField("Chip", "Apple M4 Max"), MacProfileField("Speicher", "64 GB"),
                MacProfileField("macOS", "27.2 (26B123)"), MacProfileField("Firmware", "13822.41.1"), uptime,
            ])
        case .critical:
            MacProfileContent(name: "Mac mini (2024)", detail: "Mac16,10", fields: [
                MacProfileField("Chip", "Apple M4"), MacProfileField("Speicher", "16 GB"),
                MacProfileField("macOS", "27.1 (a) (26A345a)"), MacProfileField("Firmware", "13822.41.1"), uptime,
            ])
        case .withoutHelper:
            MacProfileContent(name: "iMac (Retina 5K, 27-inch, 2020)", detail: "iMac20,1", fields: [
                MacProfileField("Chip", "Intel Core i7"), MacProfileField("Speicher", "32 GB"),
                MacProfileField("macOS", "27.2 (26B123)"), MacProfileField("Firmware", "–"), uptime,
            ])
        case .emptyProfile:
            MacProfileContent(name: "Dieser Mac", detail: "", fields: ["Chip", "Speicher", "macOS", "Firmware", "Laufzeit"]
                .map { MacProfileField($0, "–") })
        }
    }

    static func links(_ scene: SnapshotGallery.SecurityScene) -> [MacLinkContent] {
        let wifi = MacLinkContent(id: "network", symbol: "network", title: "Netz", summary: "WLAN (en0) · 192.168.178.24")
        let storage = MacLinkContent(id: "storage", symbol: "internaldrive", title: "Datenträger",
                                     summary: "248 GB frei von 1 TB",
                                     status: StatusItem("SMART verifiziert", tone: .positive))
        return switch scene {
        case .protected:
            [storage,
             MacLinkContent(id: "battery", symbol: "battery.75percent", title: "Akku", summary: "82 % · Netzteil",
                            status: StatusItem("Zustand normal", tone: .positive)),
             wifi]
        case .oneOpen:
            [storage,
             MacLinkContent(id: "battery", symbol: "battery.50percent", title: "Akku", summary: "46 % · Lädt",
                            status: StatusItem("Service empfohlen", tone: .finding)),
             wifi]
        case .critical:
            [MacLinkContent(id: "storage", symbol: "internaldrive", title: "Datenträger",
                            summary: "31 GB frei von 512 GB",
                            status: StatusItem("SMART Fehler", tone: .critical)),
             MacLinkContent(id: "network", symbol: "network", title: "Netz", summary: "Ethernet (en0) · 10.0.0.12")]
        case .withoutHelper:
            [MacLinkContent(id: "network", symbol: "network", title: "Netz", summary: "Keine aktive Verbindung",
                            status: StatusItem("Offline", tone: .neutral))]
        case .emptyProfile:
            []
        }
    }

    static func selection(_ scene: SnapshotGallery.SecurityScene) -> String? {
        switch scene {
        case .protected, .emptyProfile: nil
        case .oneOpen, .withoutHelper: "firewall"
        case .critical: "sip"
        }
    }

    static func offers(_ id: String, scene: SnapshotGallery.SecurityScene) -> [String] {
        switch (id, scene) {
        case ("firewall", .oneOpen): ["Tarnmodus einschalten"]
        case ("firewall", .withoutHelper): ["Firewall einschalten", "Tarnmodus einschalten"]
        case ("pendingUpdates", _): ["Jetzt suchen", "Softwareupdate öffnen"]
        case ("xprotect", _): ["XProtect aktualisieren"]
        default: []
        }
    }

    static func checks(_ scene: SnapshotGallery.SecurityScene) -> [CheckItem] {
        let good = StatusItem("In Ordnung", tone: .positive)
        func item(_ id: String, _ symbol: String, _ title: String, _ reason: String, _ status: StatusItem? = nil,
                  explanation: String? = nil, details: [String] = []) -> CheckItem {
            CheckItem(id: id, symbol: symbol, title: title, reason: reason, status: status ?? good,
                      explanation: explanation, details: details)
        }
        let firewall = switch scene {
        case .protected, .critical, .emptyProfile:
            item("firewall", "firewall", "Firewall", "Firewall und Tarnmodus sind eingeschaltet.")
        case .oneOpen:
            item("firewall", "firewall", "Firewall", "Firewall an, Tarnmodus aus – der Mac antwortet auf Anfragen wie Ping.",
                 StatusItem("Hinweis", tone: .finding))
        case .withoutHelper:
            item("firewall", "firewall", "Firewall", "Die Firewall ist ausgeschaltet.", StatusItem("Kritisch", tone: .critical))
        }
        let sip = scene == .critical
            ? item("sip", "lock.shield.fill", "Systemintegritätsschutz (SIP)", "Der Systemintegritätsschutz ist ausgeschaltet.",
                   StatusItem("Kritisch", tone: .critical),
                   explanation: "Einschalten geht nur im Wiederherstellungsmodus: Mac im Wiederherstellungsmodus starten, "
                       + "Terminal öffnen, „csrutil enable“ ausführen und neu starten.")
            : item("sip", "lock.shield.fill", "Systemintegritätsschutz (SIP)", "Der Systemintegritätsschutz ist aktiv.")
        let xprotect = scene == .withoutHelper
            ? item("xprotect", "shield.lefthalf.filled", "XProtect", "Konnte nicht geprüft werden: keine Leserechte.",
                   StatusItem("Nicht prüfbar", tone: .neutral), details: ["Zuletzt bekannt: in Ordnung"])
            : item("xprotect", "shield.lefthalf.filled", "XProtect", "Version 5321, installiert vor 3 Tagen.")
        let updates = scene == .critical
            ? item("pendingUpdates", "arrow.down.circle.fill", "Ausstehende Updates", "2 Updates ausstehend.",
                   StatusItem("Hinweis", tone: .finding),
                   details: ["macOS 27.1 – seit 5 Tagen", "Safari 27.1 – seit 2 Tagen", "Letzte Suche: gestern"])
            : item("pendingUpdates", "arrow.down.circle.fill", "Ausstehende Updates", "Keine Updates ausstehend.")
        return [
            item("fileVault", "lock.fill", "FileVault", "FileVault ist eingeschaltet – die Festplatte ist verschlüsselt."),
            item("automaticLogin", "person.badge.key.fill", "Automatische Anmeldung",
                 "Die automatische Anmeldung ist aus – beim Start fragt der Mac nach dem Passwort."),
            firewall,
            item("sharingServices", "person.2.fill", "Freigabedienste",
                 "Bildschirmfreigabe, Dateifreigabe und entfernte Anmeldung sind aus."),
            sip,
            item("gatekeeper", "checkmark.seal.fill", "Gatekeeper", "Gatekeeper prüft Apps vor dem ersten Öffnen."),
            xprotect,
            item("automaticUpdates", "arrow.triangle.2.circlepath", "Automatische Updates",
                 "Automatische Updates sind vollständig eingeschaltet."),
            updates,
            item("mdmEnrollment", "building.2.fill", "Geräteverwaltung (MDM)",
                 "Dieser Mac ist bei keiner Geräteverwaltung (MDM) angemeldet."),
        ]
    }
}

/// Aktionen einer aufgeklappten Prüfung wie in der App.
private struct SecurityOffersSample: View {
    let offers: [String]
    let isEnabled: Bool

    var body: some View {
        if !offers.isEmpty {
            HStack(spacing: InstrumentSpacing.group) {
                ForEach(offers, id: \.self) { title in
                    Button(title) {}.disabled(!isEnabled)
                }
            }
            .padding(.top, InstrumentSpacing.stack)
        }
    }
}
