import SwiftUI

/// Gastgeber, wenn Xcode den Prozess für SwiftUI-Vorschauen startet (`RuntimeEnvironment.LaunchMode.previewHost`):
/// hält nur die App am Laufen, damit die `#Preview`s (mit festen Daten) gerendert werden. Ohne `AppDelegate`, Modelle,
/// Hauptfenster, Menüleiste und Onboarding – also ohne Helper, Login-Item, Überwachung, Ablage, Benachrichtigungen
/// und Update-Prüfung. Die leere Einstellungs-Szene öffnet von selbst kein Fenster.
struct PreviewHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
