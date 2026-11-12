import GrantryCharts
import SwiftUI

/// Entwurf LB-4.1 (#547): Aufräumen › Speicher – Kategorien nach Größe mit Spur des Anteils, Risiko und Status, eine
/// aufgeklappt mit Häkchenzeilen, Time-Machine-Vorschläge und „Zuletzt aufgeräumt“; vor dem Scan mit fehlendem
/// Festplattenvollzugriff, Scan läuft, Aufräumen läuft, Teilerfolg. Ordner und Werte sind erfunden.
struct StorageDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Aufräumen › Speicher",
                      subtitle: "Entwurf LB-4.1: Kategorien mit Spur je Anteil, Einträge als Häkchenzeilen, Time Machine "
                          + "und Protokoll im selben Panel, Aktionsleiste unten – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Ergebnis (Vorauswahl wie heute: nur Risiko gering, keine Sperre)")
            Self.primary
            AreaDraftCaption(text: "2 · Vor dem Scan ohne Festplattenvollzugriff (links) und Scan läuft (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Noch nicht gescannt", shield: .calm, items: [], facts: "liest nur auf Knopfdruck"),
                                   segment: .storage, isUnchecked: true, height: CleanupDraftHeight.state) {
                    InstrumentBanner("Festplattenvollzugriff fehlt", message: "Ohne ihn erfasst Grantry geschützte Ordner nicht – ihre Größen fehlen in "
                                          + "den Summen.", tone: .finding) { Button("Systemeinstellungen öffnen") {}; Button("Einrichtung …") {} }
                } content: {
                    InstrumentEmptyState(symbol: "internaldrive", title: "Noch nicht gescannt",
                                         message: "Der Scan startet nur, wenn du ihn anstößt. Gelöscht wird erst nach "
                                             + "deiner Bestätigung.")
                } bar: {
                    StorageBar(scope: "Nichts ausgewählt", isIdle: true)
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Scan läuft", shield: .calm, items: [], facts: "3 von 9 Kategorien"),
                                   segment: .storage, isUnchecked: true,
                                   progress: CoverageSample(title: "Scan läuft", detail: "Xcode-Daten · Dauer noch unbekannt",
                                                           fraction: nil, tone: .info),
                                   height: CleanupDraftHeight.state) {
                    CleanupDraftList { StorageCategories(expandsFirst: false) }
                } bar: {
                    StorageBar(scope: "Nichts ausgewählt", isScanning: true)
                }
            }
            AreaDraftCaption(text: "3 · Aufräumen läuft (links) und Teilerfolg mit Details (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: StorageSamples.narrowVerdict, segment: .storage, progress: StorageSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    CleanupDraftList { StorageCategories(expandsFirst: true, expandsOthers: false, isLocked: true) }
                } bar: {
                    StorageBar(scope: "Ausgewählt: 2 Einträge · 13,1 GB", runningText: "Wird aufgeräumt …")
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "13,1 GB frei geworden", shield: .calm, items: [], facts: "Scan 14:32"),
                                   segment: .storage, progress: StorageSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    InstrumentBanner("1 von 2 Einträgen aufgeräumt", message: "1 übersprungen: wird gerade benutzt. Lokale Snapshots belegen weiter "
                                          + "Platz, bis macOS sie entfernt.", tone: .finding) { BannerDismissButton {} }
                } content: {
                    CleanupDraftList {
                        SelectionGroupHeader(title: "Details", count: 2)
                        OutcomeRow(StatusItem("aufgeräumt", tone: .positive),
                                        target: "~/Library/Developer/Xcode/DerivedData (Papierkorb)")
                        OutcomeRow(StatusItem("übersprungen", tone: .neutral),
                                        target: "~/Library/Caches/com.example.browser (Papierkorb)",
                                        reason: "Wird gerade benutzt von Beispiel-Browser")
                        SelectionGroupHeader(title: "Lokale Snapshots", count: 1)
                        DetailItem(InstrumentRowContent(symbol: "clock.arrow.circlepath", title: "Time-Machine-Snapshot",
                                                        detail: "heute, 13:00 · Grantry führt den Befehl nicht aus")) {
                            DetailEntry("Befehl", value: "tmutil deletelocalsnapshots 2026-11-11-130000", isCode: true)
                        } actions: {
                            Button("Befehl kopieren") {}
                        }
                    }
                } bar: {
                    StorageBar(scope: "Nichts ausgewählt")
                }
            }
        }
    }
}

extension StorageDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        CleanupDraftScreen(verdict: StorageSamples.verdict, segment: .storage, progress: StorageSamples.fresh,
                           height: CleanupDraftHeight.storage) {
            CleanupDraftList {
                StorageCategories(expandsFirst: true)
                StorageTimeMachine()
                StorageRecentLog()
            }
        } bar: {
            StorageBar(scope: "Ausgewählt: 2 Einträge · 13,1 GB")
        }
    }
}

// MARK: - Beispieldaten

private enum StorageSamples {
    static let verdict = InventoryHead(verdict: "28,4 GB aufräumbar", shield: .finding, items: [StatusItem("1 Ordner nicht erfasst", tone: .finding), StatusItem("2 Vorschläge Time Machine", tone: .neutral)], facts: "9 Kategorien · Scan 14:32")
    static let narrowVerdict = InventoryHead(verdict: "28,4 GB aufräumbar", shield: .finding, items: [StatusItem("1 nicht erfasst", tone: .finding)], facts: "Scan 14:32")
    static let fresh = CoverageSample(title: "Scan vollständig", detail: "9 Kategorien gelesen · 14:32", fraction: 1,
                                     tone: .positive)
    static let low = StatusItem("Risiko gering", tone: .neutral)
    static let medium = StatusItem("Risiko mittel", tone: .neutral)
}

/// Kategorien nach Größe; die erste aufgeklappt mit Einträgen (vorausgewählt nur Risiko gering), ein Eintrag mit
/// Befehl statt Häkchen (nur Bericht).
private struct StorageCategories: View {
    let expandsFirst: Bool
    var expandsOthers: Bool?
    var isLocked = false

    var body: some View {
        StorageSampleCategory(title: "Xcode-Daten", summary: "Zwischenstände, die Xcode neu erzeugt", risk: StorageSamples.low,
                             size: "18,6 GB", share: 0.65, isExpanded: expandsFirst,
                             note: "Time Machine: teilweise gesichert") {
            SelectionCheckRow("DerivedData", detail: "~/Library/Developer/Xcode/DerivedData · zuletzt benutzt vor 9 Tagen",
                              size: "12,8 GB", isOn: .constant(true))
                .disabled(isLocked)
            SelectionCheckRow("Archives", detail: "~/Library/Developer/Xcode/Archives", size: "5,5 GB",
                              isOn: .constant(false), hint: StorageSamples.medium)
                .disabled(isLocked)
            ReportRow(symbol: "lock", title: "Module-Cache", detail: "Wird gerade benutzt von Xcode", size: "310 MB") {
                Button("Im Finder zeigen") {}
            }
        }
        StorageSampleCategory(title: "Caches", summary: "Zwischenspeicher von Apps", risk: StorageSamples.low,
                             size: "6,2 GB", share: 0.22, isExpanded: false) { EmptyView() }
        StorageSampleCategory(title: "Simulator-Laufzeiten", summary: "Nicht mehr benutzte Laufzeiten",
                             risk: StorageSamples.medium, size: "3,1 GB", share: 0.11, isExpanded: expandsOthers ?? expandsFirst,
                             note: nil) {
            ReportRow(symbol: "terminal", title: "iOS 25.4", detail: "nur mit Befehl entfernbar", size: "3,1 GB") {
                Button("Befehl kopieren") {}
            }
        }
        StorageSampleCategory(title: "Mail-Anhänge", summary: "Geschützter Ordner", risk: StorageSamples.low,
                             status: StatusItem("nicht erfasst", tone: .finding), size: "–", share: nil,
                             isExpanded: false) { EmptyView() }
    }
}

/// Time-Machine-Vorschläge (#227): eigene Gruppe mit Häkchen und zwei Knöpfen; vorausgewählt nur Risiko gering und
/// gesichert.
private struct StorageTimeMachine: View {
    var body: some View {
        SelectionGroupHeader(title: "Time-Machine-Vorschläge", count: 2)
        SelectionCheckRow("Caches", detail: "~/Library/Caches · gesichert", size: "6,2 GB", isOn: .constant(true),
                          hint: StorageSamples.low)
        SelectionCheckRow("Xcode-Daten", detail: "~/Library/Developer · ausgenommen", size: "18,6 GB",
                          isOn: .constant(false), hint: StorageSamples.medium)
        HStack(spacing: InstrumentSpacing.group) {
            Button("Aus Time Machine ausnehmen …") {}
            Button("Wieder sichern …") {}
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, InstrumentSpacing.group)
        InstrumentNote("Lässt sich neu erzeugen oder herunterladen. Grantry ändert nur die Sicherung, nicht die Ordner.")
            .padding(.horizontal, InstrumentSpacing.group)
    }
}

/// „Zuletzt aufgeräumt“ mit Zustandschip je Eintrag und Sprung zum Protokoll.
private struct StorageRecentLog: View {
    var body: some View {
        SelectionGroupHeader(title: "Zuletzt aufgeräumt", count: 2)
        OutcomeRow(StatusItem("aufgeräumt", tone: .positive),
                        target: "10.11.2026, 18:04 – ~/Library/Caches/com.example.editor")
        OutcomeRow(StatusItem("fehlgeschlagen", tone: .critical),
                        target: "10.11.2026, 18:04 – ~/Downloads/Beispiel-Installer.dmg",
                        reason: "Keine Berechtigung")
        Button("Protokoll im Finder zeigen") {}.buttonStyle(.link).font(InstrumentFont.label)
            .padding(.horizontal, InstrumentSpacing.group)
    }
}

/// Leiste des Speichers: Scannen bzw. Abbrechen, Optionen, Umfang, „Aufräumen …“.
private struct StorageBar: View {
    let scope: String
    var runningText: String?
    var isIdle = false
    var isScanning = false

    var body: some View {
        InstrumentActionBar(scope: scope, runningText: runningText) {
            if isScanning {
                Button("Abbrechen") {}
            } else {
                Button("Scannen") {}.disabled(runningText != nil)
            }
            Button("Optionen …") {}
        } trailing: {
            Button("Aufräumen …", role: .destructive) {}
                .disabled(isIdle || isScanning || runningText != nil || scope == "Nichts ausgewählt")
        }
    }
}

// MARK: - Kategorie aus zentralen Bausteinen

/// Kategorie wie in der Ansicht (LB-4.3, #549): `DisclosureSection` mit `StorageCategoryHead`, Zustand fest.
private struct StorageSampleCategory<Items: View>: View {
    let title: String
    let summary: String
    let risk: StatusItem
    var status: StatusItem?
    let size: String
    let share: Double?
    let isExpanded: Bool
    var note: String?
    @ViewBuilder let items: Items

    var body: some View {
        let sentence = [summary, note].compactMap { $0 }.joined(separator: " · ")
        DisclosureSection(title, value: StorageCategoryHead.spokenValue(size: size, share: share, risk: risk,
                                                                         status: status, summary: sentence),
                          isExpanded: .constant(isExpanded), togglesOnHead: true) {
            StorageCategoryHead(title: title, summary: sentence, risk: risk, status: status, size: size, share: share)
        } content: {
            items
        }
        .padding(.leading, InstrumentSpacing.group)
    }
}

#Preview("LB-4.1 Speicher") {
    ScrollView { DesignGallery(page: .storageDraft) }
}
