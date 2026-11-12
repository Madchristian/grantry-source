import SwiftUI
@testable import GrantryCharts

/// Aufräumen › Speicher im Lagebild (LB-4.3, #549) mit festen Beispieldaten wie im abgenommenen Entwurf LB-4.1 (#547):
/// Ergebnis, vor dem Scan ohne Festplattenvollzugriff, Scan läuft, Aufräumen läuft und Teilerfolg. Erfundene Ordner unter
/// `com.example`, keine Benutzernamen oder echten Pfade. Texte wie aus `StoragePresentation` (ManagerKit).
@MainActor
extension SnapshotGallery {
    enum StorageScene: String, CaseIterable, Sendable {
        case result = "ergebnis"
        case notScanned = "kein-scan"
        case scanning = "scan-laeuft"
        case cleaning = "aufraeumen-laeuft"
        case partial = "teilerfolg"
    }

    static let storageSize = CGSize(width: 1000, height: 900)

    static func storage(_ scene: StorageScene) -> some View {
        StorageBoardSample(scene: scene)
    }
}

private enum StorageSampleData {
    static let low = StatusItem("Risiko gering", tone: .neutral)
    static let medium = StatusItem("Risiko mittel", tone: .neutral)
    static let resultHead = InventoryHead(
        verdict: "28,4 GB aufräumbar", finding: true,
        items: [StatusItem("1 Ordner nicht erfasst", tone: .finding),
                StatusItem("2 Vorschläge Time Machine", tone: .neutral)],
        facts: "4 Kategorien")
    static let complete = CleanupProgress(title: "Scan unvollständig", detail: "4 Kategorien gelesen", fraction: 1,
                                          tone: .finding)
    static let selection = "Ausgewählt: 2 Einträge · 13,1 GB"
}

private struct StorageBoardSample: View {
    let scene: SnapshotGallery.StorageScene

    var body: some View {
        CleanupBoard(head: head, progress: progress) {
            InstrumentSegments("Bereich", selection: .constant(1),
                               options: [(0, "App-Reste"), (1, "Speicher"), (2, "Prozesse"), (3, "Belegung")])
        } banner: {
            switch scene {
            case .notScanned:
                InstrumentBanner("Voraussetzungen fehlen",
                                 message: "Ohne Festplattenvollzugriff erfasst Grantry geschützte Ordner nicht – ihre "
                                     + "Größen fehlen in den Summen.", tone: .finding)
            case .partial:
                InstrumentBanner("1 von 2 Einträgen aufgeräumt",
                                 message: "12,8 GB in den Papierkorb gelegt (frei nach dem Leeren), 1 übersprungen",
                                 tone: .finding)
            case .result, .scanning, .cleaning:
                EmptyView()
            }
        } content: {
            if scene == .notScanned {
                InstrumentEmptyState(symbol: "internaldrive", title: "Noch nicht gescannt",
                                     message: "Der Scan startet nur, wenn du ihn anstößt. Gelöscht wird erst nach "
                                         + "deiner Bestätigung.")
            } else {
                CleanupFindingList { findings }
            }
        } bar: {
            InstrumentActionBar(scope: scene == .result || scene == .cleaning ? StorageSampleData.selection
                                    : "Nichts ausgewählt",
                                runningText: scene == .cleaning ? "Wird aufgeräumt …" : nil) {
                Button(scene == .scanning ? "Abbrechen" : "Scannen") {}
                Button("Optionen …") {}
            } trailing: {
                Button("Aufräumen …", role: .destructive) {}.disabled(scene != .result)
            }
        }
    }

    private var head: InventoryHead {
        switch scene {
        case .notScanned:
            InventoryHead(verdict: "Noch nicht gescannt", shield: .open, items: [], facts: "liest nur auf Knopfdruck")
        case .scanning:
            InventoryHead(verdict: "Scan läuft", shield: .open, items: [], facts: "3 Kategorien gelesen")
        case .result, .cleaning, .partial:
            StorageSampleData.resultHead
        }
    }

    private var progress: CleanupProgress? {
        switch scene {
        case .notScanned: nil
        case .scanning: CleanupProgress(title: "Scan läuft", detail: "Dauer noch unbekannt", fraction: nil, tone: .info)
        case .result, .cleaning, .partial: StorageSampleData.complete
        }
    }

    @ViewBuilder
    private var findings: some View {
        if scene == .result {
            InstrumentNote("Nicht erfassbar: 1 Ordner – ohne Leserecht fehlen ihre Größen in den Summen.", kind: .finding)
                .padding(.horizontal, InstrumentSpacing.group)
        }
        if scene == .partial {
            SelectionGroupHeader(title: "Details", count: 2)
            OutcomeRow(StatusItem("aufgeräumt", tone: .positive),
                       target: "~/Library/Developer/Xcode/DerivedData (Papierkorb)")
            OutcomeRow(StatusItem("übersprungen", tone: .neutral),
                       target: "~/Library/Caches/com.example.browser (Papierkorb)",
                       reason: "Wird gerade benutzt von Beispiel-Browser")
        }
        category("Xcode-Daten", "Zwischenstände, die Xcode neu erzeugt · Time Machine: teilweise gesichert",
                 risk: StorageSampleData.low, size: "18,6 GB", share: 0.65,
                 isExpanded: scene == .result || scene == .cleaning) {
            SelectionCheckRow("DerivedData", detail: "~/Library/Developer/Xcode/DerivedData · zuletzt benutzt vor 9 Tagen",
                              size: "12,8 GB", isOn: .constant(true))
                .disabled(scene == .cleaning)
            SelectionCheckRow("Archives", detail: "~/Library/Developer/Xcode/Archives", size: "5,5 GB",
                              isOn: .constant(false))
                .disabled(scene == .cleaning)
            // Ohne Verweis-Knopf: Links zeichnet `ImageRenderer` nicht, die Galerie zeigt sie (offscreen).
            ReportRow(symbol: "lock", title: "Module-Cache", detail: "Wird gerade benutzt von Xcode", size: "310 MB")
        }
        category("Caches", "Zwischenspeicher von Apps", risk: StorageSampleData.low, size: "6,2 GB", share: 0.22,
                 isExpanded: false) { EmptyView() }
        category("Simulator-Laufzeiten", "Nicht mehr benutzte Laufzeiten", risk: StorageSampleData.medium,
                 size: "3,1 GB", share: 0.11, isExpanded: scene == .result) {
            ReportRow(symbol: "terminal", title: "iOS 25.4", detail: "nur mit Befehl entfernbar", size: "3,1 GB")
        }
        category("Mail-Anhänge", "Geschützter Ordner", risk: StorageSampleData.low,
                 status: StatusItem("Festplattenvollzugriff nötig", tone: .finding), size: "0 Byte", share: nil,
                 isExpanded: false) { EmptyView() }
        if scene == .result {
            SelectionGroupHeader(title: "Time-Machine-Vorschläge", count: 2)
            SelectionCheckRow("Caches", detail: "~/Library/Caches · gesichert", size: "6,2 GB", isOn: .constant(true),
                              hint: StorageSampleData.low)
            SelectionCheckRow("Xcode-Daten", detail: "~/Library/Developer · ausgenommen", size: "18,6 GB",
                              isOn: .constant(false), hint: StorageSampleData.medium)
            InstrumentNote("Lässt sich neu erzeugen oder herunterladen. Grantry ändert nur die Sicherung, nicht die Ordner.")
                .padding(.horizontal, InstrumentSpacing.group)
            SelectionGroupHeader(title: "Zuletzt aufgeräumt", count: 2)
            OutcomeRow(StatusItem("aufgeräumt", tone: .positive),
                       target: "10.11.2026, 18:04 – ~/Library/Caches/com.example.editor")
            OutcomeRow(StatusItem("fehlgeschlagen", tone: .critical),
                       target: "10.11.2026, 18:04 – ~/Downloads/Beispiel-Installer.dmg", reason: "Keine Berechtigung")
        }
    }

    private func category<Items: View>(_ title: String, _ summary: String, risk: StatusItem, status: StatusItem? = nil,
                                       size: String, share: Double?, isExpanded: Bool,
                                       @ViewBuilder items: () -> Items) -> some View {
        DisclosureSection(title, value: StorageCategoryHead.spokenValue(size: size, share: share, risk: risk,
                                                                         status: status, summary: summary),
                          isExpanded: .constant(isExpanded), togglesOnHead: true) {
            StorageCategoryHead(title: title, summary: summary, risk: risk, status: status, size: size, share: share)
        } content: {
            items()
        }
        .padding(.leading, InstrumentSpacing.group)
    }
}
