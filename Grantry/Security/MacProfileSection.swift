import GrantryCharts
import ManagerKit
import SwiftUI

/// Linke Spalte des Bereichs „Sicherheit“ (TM-16.3, #408): Steckbrief und Sprungzeilen. Liest beim Öffnen einmal
/// (`MacProfileSource`, `MacLinkSource`), kein Takt; die Laufzeit gilt für diesen Zeitpunkt. Die Seriennummer liest erst
/// der Klick auf „Einblenden“; sie liegt nur im Zustand dieser Ansicht und ist beim nächsten Öffnen wieder verdeckt. Bis
/// zum Steckbrief steht ein Platzhalter, an dem die Ladung hängt (`LoadingSlot`, #479).
struct MacProfileSection: View {
    @Environment(MainWindowModel.self) private var window
    @State private var profile: MacProfile?
    @State private var links: [MacLink] = []
    @State private var openedAt = Date.now
    @State private var serial = SerialNumberReveal()

    var body: some View {
        LoadingSlot(profile) { profile in
            MacProfileColumn(profile: MacProfileMapping.content(profile, at: openedAt),
                             serial: SecretValue(text: serial.text, isRevealed: serial.isRevealed,
                                                 isBusy: serial.isLoading),
                             links: links.map(MacProfileMapping.content), toggleSerial: toggleSerial, open: open)
        } placeholder: {
            MacProfileLoadingPanel()
        } load: {
            openedAt = .now
            profile = await MacProfileSource.shared.profile()
            links = await MacLinkSource.shared.links()
        }
    }

    private func open(_ id: MacLink.ID) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        window.show(MacProfileMapping.request(for: link.kind))
    }

    private func toggleSerial() {
        guard serial.toggle() else { return }
        Task {
            let number = await MacProfileSource.shared.serialNumber()
            serial.finish(number)
        }
    }
}

/// Zuordnung von Steckbrief und Sprungzeilen (ManagerKit) zu den Inhalten der Tafel (GrantryCharts) und den Zielen im
/// Hauptfenster.
enum MacProfileMapping {
    static func content(_ profile: MacProfile, at now: Date) -> MacProfileContent {
        MacProfileContent(name: MacProfilePresentation.name(of: profile), detail: MacProfilePresentation.detail(of: profile),
                          fields: MacProfilePresentation.fields(of: profile, at: now).map {
                              MacProfileField($0.title, $0.value)
                          })
    }

    static func content(_ link: MacLink) -> MacLinkContent {
        MacLinkContent(id: link.id, symbol: link.symbol, title: link.title, summary: link.summary,
                       status: link.status.map { StatusItem($0.text, tone: $0.tone.statusTone) })
    }

    /// Datenträger nach Aufräumen › Belegung (#403, #448), Akku nach Task-Manager › Energie, Netz nach Task-Manager ›
    /// Leistung.
    static func request(for kind: MacLink.Kind) -> MainWindowRequest {
        switch kind {
        case .storage: MainWindowRequest(section: .cleanup, cleanupSegment: .occupancy)
        case .battery: MainWindowRequest(section: .taskManager, taskManagerTab: .energy)
        case .network: MainWindowRequest(section: .taskManager, taskManagerTab: .performance)
        }
    }
}
