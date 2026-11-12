import GrantryCharts
import SwiftUI

// Entwurf LB-4.1 (#547, Spec docs/superpowers/specs/2026-11-10-lagebild-altansichten-design.md § 3.1, § 4.3, § 5 Welle 4):
// gemeinsames Gerüst der Aufräumen-Segmente Reste, Speicher und Prozesse. Nur Galerie mit festen Beispieldaten; benutzt
// die zentralen Bausteine aus LB-1.2 (#536) und das Gerüst aus LB-2.1 (`LagebildAreaDraft.swift`) und verändert sie nicht.
// Die Vorschläge des Entwurfs sind mit #548 bis #551 zentral geworden; Banner zeichnet seit LB-5.5 (#556) direkt
// `InstrumentBanner`.

// MARK: - Gerüst

/// Segmente im Bereich „Aufräumen“ wie heute (`CleanupSegment`); Belegung ist schon im Lagebild (#403).
enum CleanupDraftSegment: Hashable {
    case leftovers, storage, processes, occupancy

    static let options: [(value: Self, label: String)] = [
        (.leftovers, "App-Reste"), (.storage, "Speicher"), (.processes, "Prozesse"), (.occupancy, "Belegung"),
    ]
}

/// Ein Aufräumen-Segment im Lagebild: Zustandszeile, Umschalter im Inhalt mit Scan-Fortschritt bzw. Stand daneben,
/// darunter auf Wunsch ein Banner (Ergebnis, veraltet, Voraussetzung) und das Fund-Panel mit der Aktionsleiste unten.
struct CleanupDraftScreen<Banner: View, Content: View, Bar: View>: View {
    let verdict: InventoryHead
    let segment: CleanupDraftSegment
    /// Noch kein Ergebnis (vor dem ersten Scan, erster Scan läuft): Schild ohne Häkchen statt Entwarnung.
    var isUnchecked = false
    /// Scan-Fortschritt oder Stand des Ergebnisses als Spur; `nil` ohne Scan.
    var progress: CoverageSample?
    /// Mindesthöhe des Fund-Panels im Bild; im Fenster füllt es die Höhe und rollt im Inneren.
    let height: CGFloat
    @ViewBuilder let banner: Banner
    @ViewBuilder let content: Content
    @ViewBuilder let bar: Bar

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: verdict.verdict, shield: isUnchecked ? .open : verdict.shield,
                       items: isUnchecked ? [] : verdict.items, facts: verdict.facts)
            HStack(spacing: InstrumentSpacing.panel) {
                InstrumentSegments("Bereich", selection: .constant(segment), options: CleanupDraftSegment.options)
                    .fixedSize()
                if let progress {
                    CoverageSampleSpur(coverage: progress)
                } else {
                    Spacer(minLength: 0)
                }
            }
            banner
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                bar
            }
            .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
            .instrumentPanel(padding: 0)
            .frame(minHeight: height, alignment: .top)
            // Im Bild ganze Höhe des Inhalts; im Fenster füllt das Panel die Höhe und rollt.
            .fixedSize(horizontal: false, vertical: true)
        }
        .areaDraftFrame()
    }
}

extension CleanupDraftScreen where Banner == EmptyView {
    init(verdict: InventoryHead, segment: CleanupDraftSegment, isUnchecked: Bool = false, progress: CoverageSample? = nil,
         height: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder bar: () -> Bar) {
        self.init(verdict: verdict, segment: segment, isUnchecked: isUnchecked, progress: progress, height: height,
                  banner: { EmptyView() }, content: content, bar: bar)
    }
}

/// Fundliste im Panel: Gruppen untereinander mit kleinem Rand (wie die Häkchenzeilen in LB-1.1).
struct CleanupDraftList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) { content }
            .padding(InstrumentSpacing.item)
    }
}

/// Höhen der Fund-Panels im Bild.
enum CleanupDraftHeight {
    static let result: CGFloat = 600
    static let state: CGFloat = 300
    static let storage: CGFloat = 700
    static let processes: CGFloat = 380
}

/// Fertige Hinweise der Beispieldaten.
enum CleanupDraftText {
    static let scope = "Ausgewählt: 3 Objekte (mindestens 1,5 GB), 1 Autostart-Eintrag"
}

// MARK: - Reste

/// Entwurf LB-4.1 (#547): Aufräumen › App-Reste – Ergebnis mit Erweiterungen ohne App, Reste je Kennung, Autostart ohne
/// Programm und Berechtigungen entfernter Apps; vor der Suche, Suche läuft, veraltet, Aktion läuft, Teilerfolg, keine
/// Reste. Kennungen, Pfade und Apps sind erfunden.
struct LeftoversDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Aufräumen › App-Reste",
                      subtitle: "Entwurf LB-4.1: Umschalter im Inhalt, Zustandszeile, Funde als Gruppen mit Häkchenzeilen, "
                          + "Aktionsleiste unten mit Umfang und Knopf – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Ergebnis (Vorauswahl wie heute: sichere Funde und Autostart-Einträge)")
            Self.primary
            AreaDraftCaption(text: "2 · Vor der Suche (links) und Suche läuft (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Noch nicht gesucht", shield: .calm, items: [], facts: "sucht nur auf Knopfdruck"),
                                   segment: .leftovers, isUnchecked: true, height: CleanupDraftHeight.state) {
                    InstrumentEmptyState(symbol: "sparkles", title: "Noch nicht gesucht",
                                         message: "Die Suche startet nur, wenn du sie anstößt. Entfernt wird erst nach "
                                             + "deiner Bestätigung.")
                } bar: {
                    LeftoverBar(scope: "Nichts ausgewählt", isSearchIdle: true)
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Suche läuft", shield: .calm, items: [], facts: "1 Erweiterung ohne App"),
                                   segment: .leftovers, isUnchecked: true,
                                   progress: CoverageSample(title: "Suche läuft",
                                                           detail: "Caches · 120 von 340 Orten", fraction: 0.35,
                                                           tone: .info),
                                   height: CleanupDraftHeight.state) {
                    CleanupDraftList { ExtensionLeftover() }
                } bar: {
                    LeftoverBar(scope: "Nichts ausgewählt", isSearching: true)
                }
            }
            AreaDraftCaption(text: "3 · Ergebnis veraltet (links) und In den Papierkorb legen läuft (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: LeftoverSamples.verdict, segment: .leftovers,
                                   progress: LeftoverSamples.stale, height: CleanupDraftHeight.state) {
                    InstrumentBanner("Ergebnis veraltet", message: "Apps haben sich seit der Suche geändert oder sie liegt länger zurück. "
                                          + "Der Papierkorb ist gesperrt, bis du erneut suchst.", tone: .finding) { Button("Erneut suchen") {} }
                } content: {
                    CleanupDraftList { LeftoverGroup() }
                } bar: {
                    LeftoverBar(scope: CleanupDraftText.scope, isLocked: true)
                }
                CleanupDraftScreen(verdict: LeftoverSamples.verdict, segment: .leftovers, progress: LeftoverSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    CleanupDraftList { LeftoverGroup() }
                } bar: {
                    LeftoverBar(scope: CleanupDraftText.scope, runningText: "Wird in den Papierkorb gelegt …")
                }
            }
            AreaDraftCaption(text: "4 · Teilerfolg (links) und keine Reste gefunden (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                CleanupDraftScreen(verdict: InventoryHead(verdict: "1 Fund offen", shield: .finding, items: [StatusItem("1 übersprungen", tone: .finding)], facts: "1 App · 12 KB"),
                                   segment: .leftovers, progress: LeftoverSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    InstrumentBanner("2 von 3 Objekten in den Papierkorb gelegt", message: "1 Objekt übersprungen: ~/Library/Preferences/com.example.scanner.plist "
                                          + "wird gerade benutzt.", tone: .finding) { Button("Papierkorb öffnen") {}; BannerDismissButton {} }
                } content: {
                    CleanupDraftList {
                        SelectionGroupHeader(title: "com.example.scanner", count: 1, size: "12 KB")
                        SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist",
                                          size: "12 KB", isOn: .constant(true))
                    }
                } bar: {
                    LeftoverBar(scope: "Ausgewählt: 1 Objekt (12 KB)")
                }
                CleanupDraftScreen(verdict: InventoryHead(verdict: "Ruhig", shield: .calm, items: [], facts: "keine Reste · Suche 14:32"),
                                   segment: .leftovers, progress: LeftoverSamples.fresh,
                                   height: CleanupDraftHeight.state) {
                    InstrumentEmptyState(symbol: "checkmark.circle", title: "Keine Reste gefunden",
                                         message: "Grantry hat keine Reste gelöschter Apps gefunden.")
                } bar: {
                    LeftoverBar(scope: "Nichts ausgewählt")
                }
            }
        }
    }
}

extension LeftoversDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        CleanupDraftScreen(verdict: LeftoverSamples.verdict, segment: .leftovers, progress: LeftoverSamples.fresh,
                           height: CleanupDraftHeight.result) {
            LeftoverFindings()
        } bar: {
            LeftoverBar(scope: CleanupDraftText.scope)
        }
    }
}

// MARK: - Beispieldaten Reste

private enum LeftoverSamples {
    static let verdict = InventoryHead(verdict: "Reste von 2 Apps", shield: .finding, items: [StatusItem("1 Erweiterung", tone: .finding), StatusItem("2 unsicher", tone: .neutral)], facts: "6 Funde · 1,6 GB")
    static let fresh = CoverageSample(title: "Suche vollständig", detail: "alle Orte gelesen · 14:32", fraction: 1,
                                     tone: .positive)
    static let stale = CoverageSample(title: "Ergebnis veraltet", detail: "Suche 14:32 · Apps seitdem geändert",
                                     fraction: 1, tone: .finding)
    static let uncertain = StatusItem("Zuordnung unsicher", tone: .info)
}

/// Funde nach der Suche: Erweiterungen ohne App (aus dem Inventar), Reste je Kennung, Autostart ohne Programm,
/// Berechtigungen entfernter Apps je Dienst. Vorauswahl wie heute: sichere Funde und verwaiste Autostart-Einträge.
private struct LeftoverFindings: View {
    var body: some View {
        CleanupDraftList {
            ExtensionLeftover()
            LeftoverGroup()
            SelectionGroupHeader(title: "com.example.notes", count: 2, size: "86 MB")
            SelectionCheckRow("Programmdaten", detail: "~/Library/Application Support/Notizblock", size: "84 MB",
                              isOn: .constant(false), hint: LeftoverSamples.uncertain)
            SelectionCheckRow("Gruppen-Container", detail: "~/Library/Group Containers/Q1W2E3.com.example.notes",
                              size: "2,1 MB", isOn: .constant(false), hint: LeftoverSamples.uncertain)
            SelectionGroupHeader(title: "Autostart-Einträge ohne Programm", count: 1)
            SelectionCheckRow("com.example.scanner.helper", detail: "~/Library/LaunchAgents · Programm fehlt",
                              size: "4 KB", isOn: .constant(true))
            SelectionGroupHeader(title: "Berechtigungen entfernter Apps", count: 1)
            DetailItem(InstrumentRowContent(symbol: "camera", title: "Kamera", detail: "Alter Scanner",
                                            status: StatusItem("erlaubt", tone: .positive))) {
                InstrumentNote("Einzeln lässt sich das nicht entfernen; „Für alle Apps zurücksetzen …“ nimmt die "
                    + "Berechtigung auch allen installierten Apps.")
            } actions: {
                Button("In Systemeinstellungen öffnen") {}
                Button("Für alle Apps zurücksetzen …") {}
            }
            InstrumentNote("Nicht durchsucht (keine Leserechte): ~/Library/Containers")
                .padding(InstrumentSpacing.group)
        }
    }
}

/// Erweiterung ohne App (heute `ExtensionLeftoversBox`) auf der Mulde mit Sprung in den Bereich.
private struct ExtensionLeftover: View {
    var body: some View {
        SelectionGroupHeader(title: "Erweiterungen ohne App", count: 1, finding: true)
        DetailItem(InstrumentRowContent(symbol: "puzzlepiece.extension", title: "Scanner-Treiber",
                                        detail: "Systemerweiterung · Beispiel GmbH",
                                        status: StatusItem("aktiv", tone: .positive), finding: true)) {
            InstrumentNote("Die App ist gelöscht, die Erweiterung läuft weiter. Entfernen über die Deinstallation des "
                + "Herstellers.", kind: .finding)
        } actions: {
            Button("In „Erweiterungen“ zeigen") {}
        }
    }
}

/// Reste einer gelöschten App mit Vorauswahl der sicheren Funde.
private struct LeftoverGroup: View {
    var body: some View {
        SelectionGroupHeader(title: "com.example.scanner", count: 3, size: "1,5 GB")
        SelectionCheckRow("Caches", detail: "~/Library/Caches/com.example.scanner", size: "1,4 GB",
                          isOn: .constant(true))
        SelectionCheckRow("Container", detail: "~/Library/Containers/com.example.scanner", size: "96 MB",
                          isOn: .constant(true))
        SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist", size: "12 KB",
                          isOn: .constant(true))
    }
}

/// Leiste der Reste: Suchen bzw. Abbrechen, Umfang, „In den Papierkorb legen …“ (gesperrt ohne Ergebnis, bei veraltetem
/// Ergebnis und während einer Aktion).
private struct LeftoverBar: View {
    let scope: String
    var runningText: String?
    var isSearchIdle = false
    var isSearching = false
    var isLocked = false

    var body: some View {
        InstrumentActionBar(scope: scope, runningText: runningText) {
            if isSearching {
                Button("Abbrechen") {}
            } else {
                Button(isSearchIdle ? "Reste gelöschter Apps suchen" : "Erneut suchen") {}
                    .disabled(runningText != nil)
            }
        } trailing: {
            Button("In den Papierkorb legen …", role: .destructive) {}
                .disabled(isSearchIdle || isSearching || isLocked || runningText != nil
                           || scope == "Nichts ausgewählt")
        }
    }
}

#Preview("LB-4.1 App-Reste") {
    ScrollView { DesignGallery(page: .leftoversDraft) }
}
