import GrantryCharts
import SwiftUI

/// Entwurf LB-4.1 (#547): Aufräumen › Prozesse – Speicherstand, verwaiste Agenten-Bäume (einer aufgeklappt) und gebootete
/// Simulatoren; vor dem Scan, Scan läuft, Beenden läuft, Teilerfolg mit „Sofort beenden“, Fehler beim Lesen, nichts
/// gefunden. Ordner, Programme und Werte sind erfunden.
struct ProcessesDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Aufräumen › Prozesse",
                      subtitle: "Entwurf LB-4.1: Speicherstand in der Zustandszeile, Agenten-Bäume und Simulatoren als "
                          + "Häkchenzeilen, Beenden in der Aktionsleiste – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Ergebnis (Vorauswahl wie heute: neu gefundene Agenten-Bäume, keine Simulatoren)")
            Self.primary
            AreaDraftCaption(text: "2 · Vor dem Scan (links) und Scan läuft (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Noch nicht gescannt", shield: .calm, items: [], facts: "liest nur auf Knopfdruck"),
                                   segment: .processes, isUnchecked: true, height: CleanupDraftHeight.state) {
                    InstrumentEmptyState(symbol: "memorychip", title: "Noch nicht gescannt",
                                         message: "Der Scan startet nur, wenn du ihn anstößt. Beendet wird erst nach "
                                             + "deiner Bestätigung.")
                } bar: {
                    ProcessBar(scope: "Nichts ausgewählt", isIdle: true)
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Scan läuft", shield: .calm, items: [], facts: "Prozesse und Simulatoren"),
                                   segment: .processes, isUnchecked: true,
                                   progress: CoverageSample(title: "Scan läuft", detail: "Dauer noch unbekannt",
                                                           fraction: nil, tone: .info),
                                   height: CleanupDraftHeight.state) {
                    InstrumentEmptyState(symbol: "magnifyingglass", title: "Prozesse werden gelesen",
                                         message: "Grantry liest Prozesse und gebootete Simulatoren – beendet nichts.")
                } bar: {
                    ProcessBar(scope: "Nichts ausgewählt", isScanning: true)
                }
            }
            AreaDraftCaption(text: "3 · Beenden läuft (links) und Teilerfolg mit Sofort beenden (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: ProcessSamples.narrowVerdict, segment: .processes,
                                   progress: ProcessSamples.fresh, height: CleanupDraftHeight.state) {
                    CleanupDraftList { ProcessFindings(expandsFirst: false, isLocked: true) }
                } bar: {
                    ProcessBar(scope: "Ausgewählt: 2 Agenten-Bäume · 7 Prozesse · 1,3 GB", runningText: "Wird beendet …")
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "1 Prozess reagiert nicht", shield: .finding, items: [StatusItem("1 läuft weiter", tone: .finding)], facts: "Arbeitsspeicher 17,0 von 32 GB"),
                                   segment: .processes, progress: ProcessSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    InstrumentBanner("1 beendet (470 MB Arbeitsspeicher), 1 läuft noch",
                                     message: "„node“ läuft nach SIGTERM weiter.", tone: .finding)
                } content: {
                    CleanupDraftList {
                        SelectionGroupHeader(title: "Details", count: 2)
                        OutcomeRow(StatusItem("beendet", tone: .positive),
                                        target: "python3 · ~/Projects/beispiel-daten")
                        OutcomeRow(StatusItem("läuft weiter", tone: .finding),
                                        target: "node · ~/Projects/beispiel-api",
                                        reason: "Reagiert nicht auf SIGTERM")
                    }
                } bar: {
                    ProcessBar(scope: "1 Agenten-Baum läuft weiter", offersForce: true)
                }
            }
            AreaDraftCaption(text: "4 · Fehler beim Lesen (links) und nichts gefunden (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Nicht vollständig gelesen", shield: .finding, items: [], facts: "Arbeitsspeicher 18,2 von 32 GB"),
                                   segment: .processes, progress: ProcessSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    CleanupDraftList {
                        InstrumentNote("Simulatoren nicht lesbar: Die Entwicklerwerkzeuge antworten nicht.",
                                       kind: .critical)
                            .padding(InstrumentSpacing.group)
                        ProcessFindings(expandsFirst: false, showsSimulators: false)
                    }
                } bar: {
                    ProcessBar(scope: "2 Agenten-Bäume · 1,3 GB")
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Ruhig", shield: .calm, items: [], facts: "Arbeitsspeicher 12,4 von 32 GB"),
                                   segment: .processes, progress: ProcessSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    InstrumentEmptyState(symbol: "checkmark.circle", title: "Nichts gefunden",
                                         message: "Keine verwaisten Agenten-Prozesse und keine gebooteten Simulatoren.")
                } bar: {
                    ProcessBar(scope: "Nichts ausgewählt")
                }
            }
        }
    }
}

extension ProcessesDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        CleanupDraftScreen(verdict: ProcessSamples.verdict, segment: .processes, progress: ProcessSamples.fresh,
                           height: CleanupDraftHeight.processes) {
            CleanupDraftList { ProcessFindings(expandsFirst: true) }
        } bar: {
            ProcessBar(scope: "Ausgewählt: 2 Agenten-Bäume · 7 Prozesse · 1,3 GB")
        }
    }
}

// MARK: - Beispieldaten

private enum ProcessSamples {
    static let verdict = InventoryHead(verdict: "3 Posten aufräumbar", shield: .finding, items: [StatusItem("2 verwaiste Agenten", tone: .finding), StatusItem("1 Simulator", tone: .neutral),
                StatusItem("Druck normal", tone: .positive)], facts: "Arbeitsspeicher 18,2 GB von 32 GB · kein Swap · 933 Prozesse")
    static let narrowVerdict = InventoryHead(verdict: "3 Posten aufräumbar", shield: .finding, items: [StatusItem("2 verwaiste Agenten", tone: .finding)], facts: "18,2 von 32 GB")
    static let fresh = CoverageSample(title: "Scan vollständig", detail: "Prozesse und Simulatoren gelesen",
                                     fraction: 1, tone: .positive)
}

/// Agenten-Bäume (neu gefundene vorausgewählt) und Simulatoren (nie vorausgewählt); der erste Baum auf Wunsch
/// aufgeklappt mit seinen Prozessen (nur Programm- und Skriptname, nie die Befehlszeile).
private struct ProcessFindings: View {
    let expandsFirst: Bool
    var isLocked = false
    var showsSimulators = true

    var body: some View {
        SelectionGroupHeader(title: "Verwaiste Agenten-Prozesse", count: 2, size: "1,3 GB", finding: true)
        DisclosureSection("node", value: "812 MB", isExpanded: .constant(expandsFirst)) {
            SelectionCheckRow("node", detail: "~/Projects/beispiel-api · läuft seit 3 Tagen · 4 Prozesse",
                              size: "812 MB", isOn: .constant(true))
                .disabled(isLocked)
        } content: {
            DisclosureMemberRow("node server.js", value: "PID 48211 · 512 MB")
            DisclosureMemberRow("node worker.js", value: "PID 48230 · 204 MB")
            DisclosureMemberRow("esbuild", value: "PID 48244 · 88 MB")
            DisclosureMemberRow("sh", value: "PID 48202 · 8 MB")
        }
        DisclosureSection("python3", value: "470 MB", isExpanded: .constant(false)) {
            SelectionCheckRow("python3", detail: "~/Projects/beispiel-daten · läuft seit 20 Stunden · 3 Prozesse",
                              size: "470 MB", isOn: .constant(true))
                .disabled(isLocked)
        } content: {
            EmptyView()
        }
        InstrumentNote("1 Agenten-Prozessbaum gehört zu einer laufenden Sitzung und wird nicht angeboten.")
            .padding(.horizontal, InstrumentSpacing.group)
        if showsSimulators {
            SelectionGroupHeader(title: "Gebootete Simulatoren", count: 1)
            SelectionCheckRow("iPhone Beispiel (iOS 27.0)", detail: "gebootet seit 2 Stunden", size: "–",
                              isOn: .constant(false))
                .disabled(isLocked)
        }
    }
}

/// Leiste der Prozesse: Scannen bzw. Abbrechen, Umfang, „Sofort beenden (SIGKILL) …“ nur nach Teilerfolg, „Beenden …“.
private struct ProcessBar: View {
    let scope: String
    var runningText: String?
    var isIdle = false
    var isScanning = false
    var offersForce = false

    var body: some View {
        InstrumentActionBar(scope: scope, runningText: runningText) {
            if isScanning {
                Button("Abbrechen") {}
            } else {
                Button("Scannen") {}.disabled(runningText != nil)
            }
        } trailing: {
            if offersForce {
                Button("Sofort beenden (SIGKILL) …") {}
            }
            Button("Beenden …", role: .destructive) {}
                .disabled(isIdle || isScanning || offersForce || runningText != nil || scope == "Nichts ausgewählt")
        }
    }
}

#Preview("LB-4.1 Prozesse") {
    ScrollView { DesignGallery(page: .processesDraft) }
}
