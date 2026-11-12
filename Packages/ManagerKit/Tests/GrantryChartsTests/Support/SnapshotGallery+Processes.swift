import SwiftUI
@testable import GrantryCharts

/// Aufräumen › Prozesse im Lagebild (LB-4.4, #550) mit festen Beispieldaten wie im abgenommenen Entwurf LB-4.1 (#547):
/// erfundene Ordner unter `~/Projects/beispiel-*`, keine Benutzernamen oder echten Pfade. Aufbau wie
/// `ProcessCleanupView`: Zustandszeile, Umschalter mit Stand, Banner, Funde, Aktionsleiste.
@MainActor
extension SnapshotGallery {
    enum ProcessesScene: String, CaseIterable, Sendable {
        case result = "ergebnis"
        case notScanned = "vor-dem-scan"
        case scanning = "scan-laeuft"
        case cleaning = "beenden-laeuft"
        case partial = "teilerfolg"
        case unreadable = "fehler"
        case nothingFound = "nichts-gefunden"
    }

    static let processesSize = CGSize(width: 1000, height: 640)

    static func processes(_ scene: ProcessesScene) -> some View {
        ProcessesSample(scene: scene)
    }
}

private enum ProcessesData {
    static let facts = "Arbeitsspeicher 18,2 GB von 32 GB · kein Swap · 933 Prozesse"
    static let head = InventoryHead(
        verdict: "3 Posten aufräumbar", finding: true,
        items: [StatusItem("2 verwaiste Agenten", tone: .finding), StatusItem("1 Simulator", tone: .neutral),
                StatusItem("Druck normal", tone: .positive)],
        facts: facts
    )
    static let fresh = CleanupProgress(title: "Scan vollständig", detail: "Prozesse und Simulatoren gelesen",
                                       fraction: 1, tone: .positive)
    static let selected = "Ausgewählt: 2 Agenten-Bäume · 7 Prozesse · 1,3 GB"
    static let nothing = "Nichts ausgewählt"
    static let members = [("node server.js", "PID 48211 · 512 MB"), ("node worker.js", "PID 48230 · 204 MB"),
                          ("esbuild", "PID 48244 · 88 MB"), ("sh", "PID 48202 · 8 MB")]
}

private struct ProcessesSample: View {
    let scene: SnapshotGallery.ProcessesScene

    var body: some View {
        switch scene {
        case .result:
            board(ProcessesData.head, progress: ProcessesData.fresh) {
                CleanupFindingList { ProcessesFindings(expandsFirst: true) }
            } bar: {
                ProcessesBar(scope: ProcessesData.selected)
            }
        case .notScanned:
            board(InventoryHead(verdict: "Noch nicht gescannt", shield: .open, items: [],
                                facts: "liest nur auf Knopfdruck"), progress: nil) {
                InstrumentEmptyState(symbol: "memorychip", title: "Noch nicht gescannt",
                                     message: "Der Scan startet nur, wenn du ihn anstößt. Beendet wird erst nach deiner "
                                         + "Bestätigung.")
            } bar: {
                ProcessesBar(scope: ProcessesData.nothing, isActionLocked: true)
            }
        case .scanning:
            board(InventoryHead(verdict: "Scan läuft", shield: .open, items: [], facts: "Prozesse und Simulatoren"),
                  progress: CleanupProgress(title: "Scan läuft", detail: "Dauer noch unbekannt", fraction: nil,
                                            tone: .info)) {
                InstrumentEmptyState(symbol: "magnifyingglass", title: "Prozesse werden gelesen",
                                     message: "Grantry liest Prozesse und gebootete Simulatoren – beendet nichts.")
            } bar: {
                ProcessesBar(scope: ProcessesData.nothing, isScanLocked: true, isActionLocked: true)
            }
        case .cleaning:
            board(ProcessesData.head, progress: ProcessesData.fresh) {
                CleanupFindingList { ProcessesFindings(isLocked: true) }
            } bar: {
                ProcessesBar(scope: ProcessesData.selected, runningText: "Wird beendet …", isScanLocked: true,
                             isActionLocked: true)
            }
        case .partial:
            board(InventoryHead(verdict: "1 Prozess reagiert nicht", finding: true,
                                items: [StatusItem("1 läuft weiter", tone: .finding),
                                        StatusItem("1 verwaister Agent", tone: .finding),
                                        StatusItem("Druck normal", tone: .positive)],
                                facts: ProcessesData.facts),
                  progress: ProcessesData.fresh) {
                InstrumentBanner("1 beendet (470 MB Arbeitsspeicher), 1 läuft noch",
                                 message: "„node“ läuft nach SIGTERM weiter.", tone: .finding)
            } content: {
                CleanupFindingList {
                    SelectionGroupHeader(title: "Details", count: 2)
                    OutcomeRow(StatusItem("beendet", tone: .positive), target: "python3")
                    OutcomeRow(StatusItem("läuft weiter", tone: .finding), target: "node",
                               reason: "1 Prozess läuft noch.")
                    ProcessesFindings(showsSecondTree: false, showsSimulators: false)
                }
            } bar: {
                ProcessesBar(scope: "Ausgewählt: 1 Agenten-Baum · 4 Prozesse · 812 MB", offersForce: true)
            }
        case .unreadable:
            board(InventoryHead(verdict: "Nicht vollständig gelesen", finding: true,
                                items: [StatusItem("2 verwaiste Agenten", tone: .finding),
                                        StatusItem("Druck normal", tone: .positive)],
                                facts: ProcessesData.facts),
                  progress: CleanupProgress(title: "Scan unvollständig", detail: "Simulatoren nicht lesbar",
                                            fraction: 1, tone: .finding)) {
                CleanupFindingList {
                    InstrumentNote("Simulatoren nicht lesbar: Die Entwicklerwerkzeuge antworten nicht.",
                                   kind: .critical)
                    ProcessesFindings(showsSimulators: false)
                }
            } bar: {
                ProcessesBar(scope: ProcessesData.selected)
            }
        case .nothingFound:
            board(InventoryHead(verdict: "Ruhig", finding: false, items: [StatusItem("Druck normal", tone: .positive)],
                                facts: "Arbeitsspeicher 12,4 GB von 32 GB · kein Swap · 812 Prozesse"),
                  progress: ProcessesData.fresh) {
                InstrumentEmptyState(symbol: "checkmark.circle", title: "Nichts gefunden",
                                     message: "Keine verwaisten Agenten-Prozesse und keine gebooteten Simulatoren.")
            } bar: {
                ProcessesBar(scope: ProcessesData.nothing, isActionLocked: true)
            }
        }
    }

    private func board(_ head: InventoryHead, progress: CleanupProgress?, @ViewBuilder content: () -> some View,
                       @ViewBuilder bar: () -> some View) -> some View {
        CleanupBoard(head: head, progress: progress, controls: { ProcessesSwitcher() }, content: content, bar: bar)
    }

    private func board(_ head: InventoryHead, progress: CleanupProgress?, @ViewBuilder banner: () -> some View,
                       @ViewBuilder content: () -> some View, @ViewBuilder bar: () -> some View) -> some View {
        CleanupBoard(head: head, progress: progress, controls: { ProcessesSwitcher() }, banner: banner,
                     content: content, bar: bar)
    }
}

private struct ProcessesSwitcher: View {
    var body: some View {
        InstrumentSegments("Bereich", selection: .constant(2),
                           options: [(0, "App-Reste"), (1, "Speicher"), (2, "Prozesse"), (3, "Belegung")])
    }
}

/// Agenten-Bäume (vorausgewählt) und Simulatoren (nie vorausgewählt), der erste Baum auf Wunsch aufgeklappt.
private struct ProcessesFindings: View {
    var expandsFirst = false
    var isLocked = false
    var showsSecondTree = true
    var showsSimulators = true

    var body: some View {
        SelectionGroupHeader(title: "Verwaiste Agenten-Prozesse", count: showsSecondTree ? 2 : 1,
                             size: showsSecondTree ? "1,3 GB" : "812 MB", finding: true)
        DisclosureSection("node", value: "812 MB", isExpanded: .constant(expandsFirst)) {
            SelectionCheckRow("node", detail: "~/Projects/beispiel-api · läuft seit 3 Tagen · 4 Prozesse",
                              size: "812 MB", isOn: .constant(true))
                .disabled(isLocked)
        } content: {
            ForEach(ProcessesData.members, id: \.0) { member in
                DisclosureMemberRow(member.0, value: member.1)
            }
        }
        if showsSecondTree {
            DisclosureSection("python3", value: "470 MB", isExpanded: .constant(false)) {
                SelectionCheckRow("python3", detail: "~/Projects/beispiel-daten · läuft seit 20 Stunden · 3 Prozesse",
                                  size: "470 MB", isOn: .constant(true))
                    .disabled(isLocked)
            } content: {
                EmptyView()
            }
        }
        InstrumentNote("1 Agenten-Prozessbaum gehört zu einer laufenden Sitzung und wird nicht angeboten.")
        if showsSimulators {
            SelectionGroupHeader(title: "Gebootete Simulatoren", count: 1, size: "2 GB")
            SelectionCheckRow("iPhone Beispiel (iOS 27.0)", detail: "gebootet seit 2 Stunden · 230 Prozesse",
                              size: "2 GB", isOn: .constant(false))
                .disabled(isLocked)
        }
    }
}

/// Leiste: Scannen, Umfang, „Sofort beenden (SIGKILL) …“ nur nach Teilerfolg, „Beenden …“.
private struct ProcessesBar: View {
    let scope: String
    var runningText: String?
    var isScanLocked = false
    var isActionLocked = false
    var offersForce = false

    var body: some View {
        InstrumentActionBar(scope: scope, runningText: runningText) {
            Button("Scannen") {}.disabled(isScanLocked)
        } trailing: {
            if offersForce {
                Button("Sofort beenden (SIGKILL) …") {}
            }
            Button("Beenden …", role: .destructive) {}.disabled(isActionLocked)
        }
    }
}
