import AppKit
import ManagerKit
import SwiftUI

/// Wunsch ans Hauptfenster: ein Bereich und optional der Eintrag, den dessen Liste hervorheben soll.
struct MainWindowRequest: Equatable {
    let section: MainSection
    var focusedRecordID: String?
    /// Öffnet danach das Blatt „Grantry deinstallieren“ (#115).
    var opensSelfUninstall = false
    /// Öffnet danach das Blatt „Installation beobachten“ (#127).
    var opensObservationStart = false
    /// Wählt im Bereich „Beobachtungen“ diese Beobachtung.
    var observationID: UUID?

    init(
        section: MainSection, focusedRecordID: String? = nil, opensSelfUninstall: Bool = false,
        opensObservationStart: Bool = false, observationID: UUID? = nil
    ) {
        self.section = section
        self.focusedRecordID = focusedRecordID
        self.opensSelfUninstall = opensSelfUninstall
        self.opensObservationStart = opensObservationStart
        self.observationID = observationID
    }

    /// Ziel eines Klicks auf eine Benachrichtigung: eine Sicherheitsprüfung, App, ein Lauscher bzw. ein Agenten-Eintrag
    /// wird in seinem Bereich hervorgehoben.
    init(_ destination: NotificationDestination) {
        switch destination {
        case .history:
            self.init(section: .history)
        case .securityCheck(let kind):
            self.init(section: .security, focusedRecordID: kind.rawValue)
        case .installedApp(let id):
            self.init(section: .apps, focusedRecordID: id)
        case .networkListener(let id):
            self.init(section: .network, focusedRecordID: id)
        case .agent(let id):
            self.init(section: .agents, focusedRecordID: id)
        case .update:
            self.init(section: .overview)
        }
    }
}

/// Öffnet das Hauptfenster von außerhalb einer View (z. B. nach einem Klick auf eine Benachrichtigung) in einem
/// bestimmten Bereich. `openWindow` gibt es nur im SwiftUI-Environment; eine stets vorhandene View (die Beschriftung
/// der Menüleiste) meldet die Aktion daher mit `register(_:)` an. Das Hauptfenster übernimmt den Wunsch aus `request`.
@MainActor
@Observable
final class MainWindowNavigator {
    /// Was das Hauptfenster zeigen soll; setzt es nach der Übernahme zurück.
    var request: MainWindowRequest?
    @ObservationIgnored private var openWindow: OpenWindowAction?

    func register(_ openWindow: OpenWindowAction) {
        self.openWindow = openWindow
    }

    /// Öffnet das Hauptfenster (oder holt es nach vorn) im Bereich `section`.
    func show(_ section: MainSection) {
        show(MainWindowRequest(section: section))
    }

    /// Öffnet das Hauptfenster dort, wohin eine angeklickte Benachrichtigung führt.
    func show(destination: NotificationDestination) {
        show(MainWindowRequest(destination))
    }

    /// Öffnet das Hauptfenster im Bereich „Apps“ mit dem Blatt „Grantry deinstallieren“.
    func showSelfUninstall() {
        show(MainWindowRequest(section: .apps, opensSelfUninstall: true))
    }

    /// Öffnet das Hauptfenster im Bereich „Beobachtungen“ mit dem Blatt „Installation beobachten“.
    func showObservationStart() {
        show(MainWindowRequest(section: .observations, opensObservationStart: true))
    }

    /// Öffnet das Hauptfenster bei der Beobachtung `id` (etwa nach dem Beenden aus der Menüleiste).
    func showObservation(_ id: UUID) {
        show(MainWindowRequest(section: .observations, observationID: id))
    }

    private func show(_ request: MainWindowRequest) {
        self.request = request
        openWindow?(id: GrantryApp.mainWindowID)
        NSApp.activate()
    }
}
