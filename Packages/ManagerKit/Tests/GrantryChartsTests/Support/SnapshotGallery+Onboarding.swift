import SwiftUI
@testable import GrantryCharts

/// Onboarding und „Was ist neu?“ im Lagebild (LB-5.3, #554) mit festen Beispieldaten wie im abgenommenen Entwurf LB-5.1
/// (#552), aufgebaut wie die App: `WindowContent` mit Lagezeile, Einrichtung als `CheckRows` samt Updates und erstem Scan
/// bzw. Höhepunkten als `HighlightRow`, unten `WindowBar`. Keine Schalter im Bild (aufgeklappt ist nie die Zeile Updates).
@MainActor
extension SnapshotGallery {
    enum OnboardingScene: String, CaseIterable, Sendable {
        /// Erster Start: Festplattenvollzugriff fehlt (aufgeklappt), weitere Schritte offen.
        case firstLaunch = "erster-start"
        /// Helper abgelehnt (aufgeklappt) mit Fehler der Einrichtung.
        case failed = "fehler"
        /// Alles eingerichtet, der erste Scan läuft (aufgeklappt mit Fortschritt).
        case scanning = "scan"
        /// Ausgangsbasis gespeichert: Schild mit Urteil.
        case done = "fertig"

        var setup: SettingsScene {
            switch self {
            case .firstLaunch: .missing
            case .failed: .failed
            case .scanning, .done: .complete
            }
        }
    }

    static let onboardingSize = CGSize(width: 620, height: 660)
    static let whatsNewSize = CGSize(width: 560, height: 440)

    static func onboarding(_ scene: OnboardingScene) -> some View {
        OnboardingSample(scene: scene).snapshotCanvas(onboardingSize)
    }

    static func whatsNew() -> some View {
        WhatsNewSample().snapshotCanvas(whatsNewSize)
    }
}

private extension View {
    func snapshotCanvas(_ size: CGSize) -> some View {
        frame(width: size.width, height: size.height, alignment: .top).instrumentBackground()
    }
}

/// Blatt „Grantry einrichten“ wie `OnboardingView`; Urteil und Zähler wie `OnboardingSummary` in ManagerKit.
private struct OnboardingSample: View {
    let scene: SnapshotGallery.OnboardingScene

    var body: some View {
        WindowContent(width: SnapshotGallery.onboardingSize.width) {
            VerdictBar(verdict: "Grantry einrichten",
                       reason: "Grantry überwacht Berechtigungen und Autostart-Einträge und meldet jede Änderung. "
                           + "Dafür braucht die App einige Freigaben.",
                       shield: scene == .done ? .calm : .open, items: [verdict], facts: "6 Schritte")
            SettingsPanel("Einrichtung", detail: progress) {
                CheckRows(items: SnapshotGallery.setupItems(scene.setup) + extraItems,
                          selection: .constant(expanded)) { item in
                    switch item.id {
                    case "setup.fullDiskAccess": DetailActions { Button("Einstellungen öffnen") {} }
                    case "setup.helper": DetailActions { Button("Genehmigen") {} }
                    case "onboarding.baseline":
                        ProgressSpur(title: "Scan läuft", detail: "42 % · noch ca. 20 s", fraction: 0.42, tone: .info)
                    default: EmptyView()
                    }
                }
                if scene == .failed {
                    InstrumentNote("Helper konnte nicht installiert werden: Die Genehmigung wurde abgelehnt.",
                                   kind: .critical)
                }
            }
        } bar: {
            WindowBar {
                Text(verbatim: "Fehlende Schritte lassen sich später in den Einstellungen nachholen.")
                    .font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                Button("Später") {}
                Button("Fertig") {}
            }
        }
    }

    private var verdict: StatusItem {
        switch scene {
        case .firstLaunch: StatusItem("4 offen", tone: .finding)
        case .failed: StatusItem("1 offen", tone: .finding)
        case .scanning: StatusItem("Scan läuft", tone: .info)
        case .done: StatusItem("bereit", tone: .positive)
        }
    }

    private var progress: String {
        switch scene {
        case .firstLaunch: "1 von 6 erledigt"
        case .failed: "4 von 6 erledigt"
        case .scanning: "5 von 6 erledigt"
        case .done: "6 von 6 erledigt"
        }
    }

    private var expanded: String? {
        switch scene {
        case .firstLaunch: "setup.fullDiskAccess"
        case .failed: "setup.helper"
        case .scanning: "onboarding.baseline"
        case .done: nil
        }
    }

    private var extraItems: [CheckItem] {
        let baseline = switch scene {
        case .firstLaunch, .failed: StatusItem("Folgt nach „Fertig“", tone: .neutral)
        case .scanning: StatusItem("läuft", tone: .info)
        case .done: StatusItem("Ausgangsbasis gespeichert", tone: .positive)
        }
        return [
            CheckItem(id: "onboarding.updates", symbol: "arrow.down.circle", title: "Updates",
                      reason: "Grantry fragt einmal täglich bei grantry.cstrube.de nach einer neuen Version.",
                      status: StatusItem("Täglich prüfen", tone: .positive),
                      explanation: "Dabei werden nur die Version von Grantry, die macOS-Version und die "
                          + "Mac-Architektur übertragen."),
            CheckItem(id: "onboarding.baseline", symbol: "viewfinder", title: "Erster Scan",
                      reason: "Der erste Scan dient als Ausgangsbasis und meldet nichts.", status: baseline,
                      explanation: "Erst Änderungen danach erscheinen im Verlauf und als Benachrichtigung."),
        ]
    }
}

/// Fenster „Was ist neu?“ wie `WhatsNewView` mit dem Inhalt aus `ReleaseHighlights.json` (2026.11.11).
private struct WhatsNewSample: View {
    var body: some View {
        WindowContent(width: SnapshotGallery.whatsNewSize.width) {
            SettingsPanel("Was ist neu?", detail: "Grantry 2026.11.11") {
                Text(verbatim: "Der Task-Manager ist da – jetzt mit Menüleisten-Anzeigen in voller Größe.")
                    .font(InstrumentFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    HighlightRow(symbol: "gauge.with.dots.needle.67percent", title: "Task-Manager im Lagebild",
                                 text: "Übersicht, Leistung je Kern, Chip mit Takt und Thermik, Prozesse, Details, "
                                     + "Energie, App-Verlauf, Benutzer und Dienste in einem Bereich.")
                    HighlightRow(symbol: "book.closed", title: "Wachbuch",
                                 text: "Auf Wunsch ein lokaler Verlauf der letzten 7 Tage: Last, Hitze und "
                                     + "Speicherdruck mit den größten Verbrauchern zu jedem Zeitpunkt.")
                    HighlightRow(symbol: "menubar.rectangle", title: "Werte in der Menüleiste",
                                 text: "CPU, GPU, Speicher, Netz, Datenträger, Thermik und Akku als eigene Anzeigen, "
                                     + "auf Retina-Bildschirmen jetzt in voller Größe – und die Übersicht im Popover.")
                    HighlightRow(symbol: "lock.shield", title: "Dieser Mac und Erweiterungen",
                                 text: "Ein Steckbrief des Macs in „Sicherheit“ und ein neuer Bereich für Kernel- und "
                                     + "Systemerweiterungen von Drittanbietern.")
                    HighlightRow(symbol: "internaldrive", title: "Belegung und Verbindungen",
                                 text: "Aufräumen zeigt, welche Ordner wie viel Platz belegen; Netzwerk zeigt alle "
                                     + "offenen Verbindungen auf einen Blick.")
                }
            }
        } bar: {
            WindowBar {
                // Der native `Link` wäre im Bild nur ein Platzhalter: Text in Linkfarbe an seiner Stelle.
                Text(verbatim: "Alle Änderungen").font(InstrumentFont.body).foregroundStyle(Color(nsColor: .linkColor))
            } actions: {
                Button("Los geht’s") {}
            }
        }
    }
}
