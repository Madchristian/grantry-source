import GrantryCharts
import SwiftUI

/// Entwurf LB-5.1 (#552): Onboarding als Blatt – Lagezeile mit Schild und Urteil, Checkliste als Prüfzeilen (dieselben
/// wie in den Einstellungen, dazu Updates und erster Scan), unten die Aktionsleiste mit „Später“ und „Fertig“.
struct OnboardingDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Onboarding",
                      subtitle: "Entwurf LB-5.1: Schild mit Urteil, Einrichtung als Prüfzeilen, Aktionsleiste unten – "
                          + "feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Erster Start: Festplattenvollzugriff fehlt (links), Helper abgelehnt (rechts)")
            Self.primary
            AreaDraftCaption(text: "2 · Alles erledigt: erster Scan läuft (links), Ausgangsbasis gespeichert (rechts)")
            GalleryRow {
                OnboardingSheet(state: .scanning)
                OnboardingSheet(state: .done)
            }
        }
    }
}

extension OnboardingDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        GalleryRow {
            OnboardingSheet(state: .firstLaunch)
            OnboardingSheet(state: .failed)
        }
    }
}

private enum OnboardingState {
    case firstLaunch, failed, scanning, done

    var setup: SetupState {
        switch self {
        case .firstLaunch: .missing
        case .failed: .failed
        case .scanning, .done: .complete
        }
    }
}

private struct OnboardingSheet: View {
    let state: OnboardingState

    var body: some View {
        GalleryWindow(name: "Blatt „Grantry einrichten“", width: GalleryWindowWidth.onboarding) {
            if state == .done {
                VerdictBar(verdict: "Grantry einrichten", reason: intro, finding: false, items: [chip],
                           facts: "6 Schritte")
            } else {
                // Vor dem ersten Scan gibt es kein Urteil: Schildform „offen“ (Abnahme LB-5.1, Spec § 11.3 c).
                VerdictBar(verdict: "Grantry einrichten", reason: intro, shield: .open, items: [chip], facts: "6 Schritte")
            }
            SettingsPanel("Einrichtung", detail: detail) {
                SetupRows(items: SetupSamples.items(state.setup) + extraItems, expanded: expanded)
                if state == .failed {
                    InstrumentNote("Helper konnte nicht installiert werden: Die Genehmigung wurde abgelehnt.",
                                   kind: .critical)
                }
            }
        } bar: {
            WindowBar {
                Text(verbatim: "Fehlende Schritte lassen sich später in den Einstellungen nachholen.")
                    .font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
            } actions: {
                Button("Später") {}.keyboardShortcut(.cancelAction)
                Button("Fertig") {}.keyboardShortcut(.defaultAction)
            }
        }
    }

    private let intro = "Grantry überwacht Berechtigungen und Autostart-Einträge und meldet jede Änderung. "
        + "Dafür braucht die App einige Freigaben."

    private var chip: StatusItem {
        switch state {
        case .firstLaunch: StatusItem("4 offen", tone: .finding)
        case .failed: StatusItem("1 offen", tone: .finding)
        case .scanning: StatusItem("Scan läuft", tone: .info)
        case .done: StatusItem("bereit", tone: .positive)
        }
    }

    private var detail: String {
        switch state {
        case .firstLaunch: "0 von 6 erledigt"
        case .failed: "4 von 6 erledigt"
        case .scanning: "5 von 6 erledigt"
        case .done: "6 von 6 erledigt"
        }
    }

    private var expanded: String? {
        state == .scanning ? "baseline" : SetupSamples.expanded(state.setup)
    }

    /// Die zwei Schritte nur im Onboarding: Updates (Zustimmung) und erster Scan als Ausgangsbasis.
    private var extraItems: [CheckItem] {
        let baseline: StatusItem = switch state {
        case .firstLaunch, .failed: StatusItem("Folgt nach „Fertig“", tone: .neutral)
        case .scanning: StatusItem("läuft", tone: .info)
        case .done: StatusItem("Ausgangsbasis gespeichert", tone: .positive)
        }
        return [
            CheckItem(id: "updates", symbol: "arrow.down.circle", title: "Updates",
                      reason: "Fragt einmal täglich nach einer neuen Version; übertragen werden nur Version, "
                          + "macOS-Version und Architektur.",
                      status: StatusItem("Täglich prüfen", tone: .positive)),
            CheckItem(id: "baseline", symbol: "viewfinder", title: "Erster Scan",
                      reason: "Dient als Ausgangsbasis und meldet nichts; erst Änderungen danach erscheinen im Verlauf.",
                      status: baseline),
        ]
    }
}

// MARK: - Was ist neu

/// Entwurf LB-5.1 (#552): Fenster „Was ist neu?“ – Peilkopf ohne Ring mit Version, Einleitung, Höhepunkte als Zeilen mit
/// Symbol im Kreis, unten Link und „Los geht’s“.
struct WhatsNewDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Was ist neu",
                      subtitle: "Entwurf LB-5.1: Peilkopf ohne Ring, Höhepunkte als Zeilen, Aktionsleiste unten – "
                          + "Inhalt wie ReleaseHighlights.json") {
            AreaDraftCaption(text: "1 · Normalfall mit fünf Höhepunkten (links), kurze Fassung mit zwei (rechts); "
                + "ohne Höhepunkte bleibt der Befehl gesperrt wie heute")
            GalleryRow {
                WhatsNewWindow(highlights: WhatsNewSamples.highlights)
                WhatsNewWindow(highlights: Array(WhatsNewSamples.highlights.prefix(2)))
            }
        }
    }
}

extension WhatsNewDraftBoard {
    /// Hauptzustand, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    static var primary: some View {
        WhatsNewWindow(highlights: WhatsNewSamples.highlights)
    }
}

private struct WhatsNewWindow: View {
    let highlights: [WhatsNewSamples.Highlight]

    var body: some View {
        GalleryWindow(name: "Fenster „Was ist neu?“", width: GalleryWindowWidth.whatsNew) {
            SettingsPanel("Was ist neu?", detail: "Grantry 2026.11.11") {
                Text(verbatim: WhatsNewSamples.intro).font(InstrumentFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    ForEach(highlights) { HighlightRow(symbol: $0.symbol, title: $0.title, text: $0.body) }
                }
            }
        } bar: {
            WindowBar {
                Link("Alle Änderungen", destination: WhatsNewSamples.releaseNotes).font(InstrumentFont.body)
            } actions: {
                Button("Los geht’s") {}.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Inhalt aus `Grantry/Updates/ReleaseHighlights.json` (2026.11.11).
private enum WhatsNewSamples {
    struct Highlight: Identifiable {
        let symbol: String
        let title: String
        let body: String
        var id: String { title }
    }

    static let releaseNotes = URL(string: "https://grantry.cstrube.de/release-notes/2026.11.11.html")!
    static let intro = "Der Task-Manager ist da – jetzt mit Menüleisten-Anzeigen in voller Größe."
    static let highlights = [
        Highlight(symbol: "gauge.with.dots.needle.67percent", title: "Task-Manager im Lagebild",
                  body: "Übersicht, Leistung je Kern, Chip mit Takt und Thermik, Prozesse, Details, Energie, "
                      + "App-Verlauf, Benutzer und Dienste in einem Bereich."),
        Highlight(symbol: "book.closed", title: "Wachbuch",
                  body: "Auf Wunsch ein lokaler Verlauf der letzten 7 Tage: Last, Hitze und Speicherdruck mit den "
                      + "größten Verbrauchern zu jedem Zeitpunkt."),
        Highlight(symbol: "menubar.rectangle", title: "Werte in der Menüleiste",
                  body: "CPU, GPU, Speicher, Netz, Datenträger, Thermik und Akku als eigene Anzeigen, auf "
                      + "Retina-Bildschirmen jetzt in voller Größe – und die Übersicht im Popover."),
        Highlight(symbol: "lock.shield", title: "Dieser Mac und Erweiterungen",
                  body: "Ein Steckbrief des Macs in „Sicherheit“ und ein neuer Bereich für Kernel- und "
                      + "Systemerweiterungen von Drittanbietern."),
        Highlight(symbol: "internaldrive", title: "Belegung und Verbindungen",
                  body: "Aufräumen zeigt, welche Ordner wie viel Platz belegen; Netzwerk zeigt alle offenen "
                      + "Verbindungen auf einen Blick."),
    ]
}

#Preview("LB-5.1 Onboarding") {
    ScrollView { DesignGallery(page: .onboardingDraft) }
}

#Preview("LB-5.1 Was ist neu") {
    ScrollView { DesignGallery(page: .whatsNewDraft) }
}
