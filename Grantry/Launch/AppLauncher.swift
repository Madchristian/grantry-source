import AppKit
import ManagerKit

/// Startpunkt des Prozesses: Zuerst werden einmalig die Daten aus der Zeit als „MacManager“ übernommen (vor jedem
/// Zugriff auf den Ablageort, auch vor der Instanzsperre); beendet sich die alte App dafür nicht, startet Grantry nicht. Läuft schon eine Grantry-Instanz, übernimmt diese, und
/// dieser Prozess endet, bevor Überwachung und Verlauf geöffnet werden – zwei Instanzen würden sonst parallel in
/// denselben Verlauf schreiben.
@main
enum AppLauncher {
    @MainActor
    static func main() {
        // Einzige Weiche für Xcode-Vorschauen (`RuntimeEnvironment.LaunchMode`): Der Vorschau-Prozess trägt die
        // Bundle-ID der installierten Grantry. Ein gestarteter Debug-Build hat schon einmal deren BTM-Eintrag (Helper
        // und Login-Item) auf DerivedData umgebogen, worauf sie den Festplattenvollzugriff verlor. Deshalb läuft hier
        // keine Startaufgabe – weder Datenübernahme, Instanzsperre noch `AppDelegate` (Helper, Login-Item,
        // Überwachung, Benachrichtigungen, Updates, Ablage); `PreviewHostApp` hält nur den Prozess für die Vorschauen.
        switch RuntimeEnvironment.current.launchMode {
        case .previewHost: PreviewHostApp.main()
        case .application: launchApplication()
        }
    }

    @MainActor
    private static func launchApplication() {
        guard LegacyDataMigration.standard.run() != .legacyAppRunning else {
            reportLegacyAppStillRunning()
            return
        }
        guard SingleInstance.claim(LaunchOptions.storage) else { return }
        GrantryApp.main()
    }

    /// MacManager hat sich nicht beendet: Grantry startet nicht, damit die Daten beim nächsten Start übernommen werden.
    @MainActor
    private static func reportLegacyAppStillRunning() {
        let alert = NSAlert()
        alert.messageText = String(localized: "MacManager läuft noch")
        alert.informativeText = String(localized: "Bitte MacManager beenden und Grantry erneut öffnen. Verlauf und Einstellungen werden dann übernommen.")
        alert.runModal()
    }
}
