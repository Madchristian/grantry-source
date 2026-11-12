import GrantryCharts
import SwiftUI

/// Entwurf LB-3.1 (#543): Beobachtungen im Lagebild – Liste, Detail mit Kopf, Bilanz (neu, geändert, entfernt) und
/// Aufräumen; Beobachtung läuft, wird beendet, Aufräumen läuft, Fehler, keine Änderungen, nicht lesbar, nichts gewählt,
/// keine Beobachtungen; Blatt „Installation beobachten“. Bestätigungen (Aufräumen, Löschen) und die Rückfrage beim Start
/// bleiben Systemdialoge bzw. das bestehende Bestätigungsblatt (Spec § 11 Entscheidung 5).
struct ObservationsDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Beobachtungen",
                      subtitle: "Entwurf LB-3.1, umgesetzt in LB-3.4: Zustandszeile, Liste, Detail mit Bilanz und "
                          + "Aufräumen, Blatt zum Starten – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Beendete Beobachtung gewählt: Bilanz und Aufräumen")
            Self.primary
            AreaDraftCaption(text: "2 · Beobachtung läuft (links) und wird beendet (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ObservationSampleDetail(sample: .running)
                ObservationSampleDetail(sample: .finishing)
            }
            .fixedSize(horizontal: false, vertical: true)
            AreaDraftCaption(text: "3 · Aufräumen läuft (links) und Fehler beim Aufräumen (rechts); Bilanz-Einträge wie in 1 "
                + "ausgelassen")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ObservationSampleDetail(sample: .compact, runningText: "Wird aufgeräumt …")
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    InstrumentBanner("Aufräumen unvollständig", message: "1 von 3 Einträgen ließ sich nicht entfernen; Details unter "
                                           + "„Aufgeräumt“.", tone: .critical) { BannerDismissButton {} }
                    ObservationSampleDetail(sample: .compactWithRecords)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            AreaDraftCaption(text: "4 · Keine Änderungen (links), Beobachtung nicht lesbar (Mitte), nichts gewählt (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ObservationSampleDetail(sample: .quiet)
                VStack(spacing: InstrumentSpacing.group) {
                    InstrumentEmptyState(symbol: "exclamationmark.triangle", title: "Beobachtung nicht lesbar",
                                         message: "Die gespeicherte Beobachtung ließ sich nicht laden.")
                    Button("Beobachtung löschen …", role: .destructive) {}
                }
                .padding(.bottom, InstrumentSpacing.empty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .instrumentPanel()
                InstrumentEmptyState(symbol: "binoculars", title: "Nichts gewählt", message: "Wähle links eine Beobachtung, um ihre Bilanz zu sehen.").instrumentPanel()
            }
            .frame(height: AreaDraftHeight.observationsState)
            AreaDraftCaption(text: "5 · Noch keine Beobachtung (links), Liste nicht lesbar (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ObservationsEmptyBoard(head: ObservationSamples.emptyHead,
                                       message: "Starte eine Beobachtung, bevor du ein Tool installierst – danach zeigt "
                                           + "Grantry, was es eingerichtet hat.") {
                    Button("Installation beobachten …") {}
                }
                .frame(height: AreaDraftHeight.empty + AreaDraftHeight.statusLine)
                .areaDraftBorder()
                ObservationsDraftScreen(height: AreaDraftHeight.empty) {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                        InstrumentNote("Eine gespeicherte Beobachtung ließ sich nicht lesen.", kind: .critical)
                        InstrumentList("Beobachtungen", count: "3", sections: [ObservationSamples.sections[1]], selection: .constant(nil))
                    }
                } detail: {
                    InstrumentEmptyState(symbol: "binoculars", title: "Nichts gewählt", message: "Wähle links eine Beobachtung, um ihre Bilanz zu sehen.").instrumentPanel()
                }
            }
            AreaDraftCaption(text: "6 · Blatt „Installation beobachten“: bereit (links), Ausgangsstand wird erfasst "
                + "(Mitte), läuft schon (rechts)")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                ObservationStartSheetDraft(state: .ready)
                ObservationStartSheetDraft(state: .starting)
                ObservationStartSheetDraft(state: .blocked)
            }
        }
    }
}

extension ObservationsDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        ObservationsDraftScreen(height: AreaDraftHeight.observations) {
            InstrumentList("Beobachtungen", count: "4", sections: ObservationSamples.sections, selection: .constant("editor"))
        } detail: {
            ObservationSampleDetail(sample: .finished)
        }
    }
}

/// Bereich mit Zustandszeile ohne Urteil (Schildform „offen“), Liste und Detail in fester Höhe.
private struct ObservationsDraftScreen<ListContent: View, DetailContent: View>: View {
    let height: CGFloat
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: DetailContent

    var body: some View {
        InventoryBoard(head: ObservationSamples.head) {
            EmptyView()
        } list: {
            list.frame(height: height)
        } detail: {
            detail.frame(height: height)
        }
        // Im Bild bestimmen Liste und Detail die Höhe; im Fenster füllt das Gerüst die Fläche.
        .fixedSize(horizontal: false, vertical: true)
        .areaDraftBorder()
    }
}

// MARK: - Detail

/// Detail einer Beobachtung aus dem zentralen `ObservationDetailPanel`, gefüllt wie in der App.
private struct ObservationSampleDetail: View {
    enum Sample { case finished, compact, compactWithRecords, running, finishing, quiet }

    let sample: Sample
    var runningText: String?

    var body: some View {
        ObservationDetailPanel(content: content) { _ in
        } actions: {
            actions
        } progress: {
            if sample == .finishing {
                ProgressSpur(title: "Abschluss-Scan", detail: "57 %", fraction: 4.0 / 7, tone: .info)
            } else if sample == .running {
                InstrumentNote("Installiere und starte jetzt das Tool. Neue Einträge erscheinen hier nach jedem Scan.",
                               kind: .info)
            }
        } rowAccessory: { _ in
            EmptyView()
        } cleanup: {
            if [.finished, .compact, .compactWithRecords].contains(sample) {
                ObservationCleanupGroup(content: ObservationSamples.cleanup.running(runningText),
                                        isSelected: { .constant(ObservationSamples.preselected.contains($0)) },
                                        removeWithLeftovers: { _ in }, remove: {})
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch sample {
        case .running, .finishing:
            DetailActions(runningText: sample == .finishing ? "Wird beendet …" : nil) {
                Button("Beobachtung beenden") {}.buttonStyle(.borderedProminent)
                Button("Beobachtung abbrechen …", role: .destructive) {}
            }
            .disabled(sample == .finishing)
        case .quiet:
            DetailActions { Button("Beobachtung löschen …", role: .destructive) {} }
        case .finished, .compact, .compactWithRecords:
            DetailActions { Button("Beobachtung löschen …", role: .destructive) {} }
                .disabled(runningText != nil)
        }
    }

    private var content: ObservationDetailContent {
        switch sample {
        case .finished, .compact, .compactWithRecords:
            ObservationDetailContent(
                title: "Beispiel-Editor", subtitle: "10. Nov. 2026, 10:12 – 10:31 (19 Min.)",
                status: StatusItem("beendet", tone: .neutral), finding: true, notes: ObservationSamples.notes,
                balance: ObservationBalanceContent(new: 5, modified: 1, removed: 0,
                                                   summary: "5 neu, 1 geändert, 0 entfernt – Bilanz unvollständig"),
                groups: sample == .finished ? ObservationSamples.finishedGroups : [],
                records: sample == .compactWithRecords ? [ObservationSamples.record] : []
            )
        case .running, .finishing:
            ObservationDetailContent(title: "Beispiel-Werkzeug", subtitle: "Seit 11. Nov. 2026, 14:20",
                                     status: StatusItem("läuft", tone: .info), groups: ObservationSamples.runningGroups)
        case .quiet:
            ObservationDetailContent(
                title: "Druckertreiber", subtitle: "8. Nov. 2026, 16:02 – 16:09 (7 Min.)",
                status: StatusItem("beendet", tone: .neutral),
                balance: ObservationBalanceContent(
                    new: 0, modified: 0, removed: 0, summary: "Keine Änderungen während der Beobachtung.",
                    note: DetailNoteContent("Während der Beobachtung ist nichts hinzugekommen, verändert oder "
                        + "verschwunden.", kind: .info))
            )
        }
    }
}

// MARK: - Blatt

/// Blatt „Installation beobachten“ aus dem zentralen `ObservationStartForm` mit Rand wie ein Blatt. Die Rückfrage
/// „Ausgangsstand unvollständig“ bleibt ein `alert`.
private struct ObservationStartSheetDraft: View {
    enum State { case ready, starting, blocked }

    let state: State

    var body: some View {
        ObservationStartForm(
            name: .constant(state == .blocked ? "" : "Beispiel-Werkzeug"), note: .constant(""),
            notes: state == .blocked
                ? [DetailNoteContent("Die Beobachtung „Beispiel-Werkzeug“ läuft bereits – es kann nur eine "
                    + "gleichzeitig laufen.", kind: .finding)] : [],
            isBusy: state == .starting, canStart: state == .ready, cancel: {}, start: {}
        ) {
            if state == .starting {
                ProgressSpur(title: "Ausgangsstand wird erfasst …", detail: "29 %", fraction: 2.0 / 7, tone: .info)
            }
        }
        .frame(width: ObservationDraftSize.sheet)
        .instrumentBackground()
        .overlay {
            RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous)
                .strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.border)
                .accessibilityHidden(true)
        }
    }
}

extension AreaDraftHeight {
    static let observations: CGFloat = 1220
    static let observationsState: CGFloat = 420
    /// Zustandszeile über dem Leerzustand.
    static let statusLine: CGFloat = 96
}

/// Breite des Blatts wie im Entwurf (480 in der App abzüglich Rand der Galerie, drei nebeneinander).
private enum ObservationDraftSize {
    static let sheet: CGFloat = 440
}

// MARK: - Beispieldaten

private enum ObservationSamples {
    static let head = InventoryHead(verdict: "1 Beobachtung läuft", shield: .open,
                                    items: [StatusItem("4 neue Einträge", tone: .info)], facts: "4 Beobachtungen")
    static let emptyHead = InventoryHead(verdict: "Keine Beobachtung", shield: .open, items: [], facts: "0 gespeichert")

    static let running = StatusItem("läuft", tone: .info)
    static let new = StatusItem("neu", tone: .info)
    static let likely = InstrumentBadge("wahrscheinlich zugehörig", tone: .neutral)
    static let unsure = InstrumentBadge("Zuordnung unsicher", tone: .finding,
                                        spoken: "Zuordnung unsicher, anderer Hersteller")

    static let sections = [
        InstrumentListSection(id: "running", title: "Läuft", tone: .info, items: [
            InstrumentListItem.sample("tool", "binoculars", "Beispiel-Werkzeug", "11. Nov. 2026, 14:20 · 4 neue Einträge",
                                      status: running),
        ]),
        InstrumentListSection(id: "saved", title: "Gespeichert", items: [
            .sample("editor", "binoculars", "Beispiel-Editor", "10. Nov. 2026, 10:12 · 5 neue Einträge"),
            .sample("printer", "binoculars", "Druckertreiber", "8. Nov. 2026, 16:02 · keine neuen Einträge"),
            .sample("sync", "binoculars", "Sync-Werkzeug", "2. Nov. 2026, 09:30 · 3 neue Einträge · aufgeräumt"),
        ]),
    ]

    static let notes = [
        DetailNoteContent("Eingeschränkt beim Start oder Ende – die Bilanz ist dort unvollständig: Agenten: "
            + "Konfiguration nicht lesbar", kind: .finding),
        DetailNoteContent("Kamera, Mikrofon, Automation und andere Berechtigungen des Benutzerbereichs liest Grantry "
            + "nicht – sie fehlen in der Bilanz.", kind: .info),
    ]

    private static func row(_ id: String, _ title: String, _ detail: String, badge: InstrumentBadge = likely,
                            destination: String) -> ObservationEntryRow {
        ObservationEntryRow(id: id, content: InstrumentRowContent(symbol: "plus", title: title, detail: detail,
                                                                  badges: [badge], status: new,
                                                                  finding: badge == unsure),
                            destination: destination)
    }

    static let newApp = row("app", "Beispiel-Editor 2.1 (Developer ID).", "App installiert", destination: "Apps")
    static let newAgent = row("agent", "com.example.editor.helper (LaunchAgent) von Beispiel-Editor.",
                              "Neuer Autostart-Eintrag", destination: "Autostart")
    static let newDaemon = row("daemon", "com.example.editor.update (LaunchDaemon) von Beispiel-Editor.",
                               "Neuer Autostart-Eintrag", destination: "Autostart")
    static let newGrant = row("grant", "Beispiel-Editor darf jetzt Bedienungshilfen.", "Neue Berechtigung",
                              destination: "Berechtigungen")
    static let newGrantUnsure = row("grant-unsure", "Fernhilfe darf jetzt Bildschirmaufnahme.", "Neue Berechtigung",
                                    badge: unsure, destination: "Berechtigungen")

    static let finishedGroups = [
        ObservationEntryGroup(id: "apps", title: "Neue Apps", rows: [newApp]),
        ObservationEntryGroup(id: "autostart", title: "Neue Autostart-Einträge", rows: [newAgent, newDaemon]),
        ObservationEntryGroup(id: "grants", title: "Neue Berechtigungen", rows: [newGrant, newGrantUnsure]),
        ObservationEntryGroup(
            id: "modified", title: "Geänderte Einträge",
            note: DetailNoteContent("Geänderte Einträge setzt Grantry nicht automatisch zurück – über den Eintrag zur "
                + "passenden Aktion wechseln.", kind: .finding),
            rows: [ObservationEntryRow(id: "server", content: InstrumentRowContent(
                symbol: "pencil", title: "„Beispiel-Server“ in ~/.config: Befehl geändert", detail: "MCP-Server geändert",
                status: StatusItem("geändert", tone: .neutral)), destination: "Agenten")]
        ),
    ]

    static let runningGroups = [
        ObservationEntryGroup(id: "apps", title: "Neue Apps", rows: [newApp]),
        ObservationEntryGroup(id: "autostart", title: "Neue Autostart-Einträge", rows: [newAgent, newDaemon]),
        ObservationEntryGroup(id: "grants", title: "Neue Berechtigungen", rows: [newGrant]),
    ]

    static let preselected: Set<String> = ["app", "agent"]

    static let cleanup = ObservationCleanupContent(
        rows: [
            ObservationCleanupRow(id: "app", title: "Beispiel-Editor.app",
                                  detail: "App · /Applications/Beispiel-Editor.app — Name passt zur Beobachtung",
                                  size: "–", offersLeftovers: true),
            ObservationCleanupRow(id: "agent", title: "com.example.editor.helper",
                                  detail: "LaunchAgent · Beispiel-Editor — gehört zu einer neuen App", size: "–"),
            ObservationCleanupRow(id: "grant", title: "Bildschirmaufnahme",
                                  detail: "Berechtigung · Fernhilfe · erlaubt — anderer Hersteller", size: "–",
                                  hint: StatusItem("Zuordnung unsicher", tone: .finding)),
        ],
        notes: [DetailNoteContent("1 neuer Eintrag ist nicht mehr (oder nicht mehr unverändert) vorhanden.", kind: .info)],
        footnote: "Angeboten wird, was von den neuen Einträgen heute noch existiert. Vorausgewählt ist nur, was "
            + "wahrscheinlich zum Tool gehört; geänderte Einträge setzt Grantry nicht zurück. Von Apps geht nur das "
            + "Programm selbst in den Papierkorb – Reste wählst du einzeln über „Mit Resten entfernen …“.",
        offersAction: true, canRemove: true, canRemoveWithLeftovers: true
    )

    static let record = ObservationRecordContent(id: "1", facts: [
        DetailFactContent("10. Nov. 2026, 10:40", value: "2 von 3 erledigt"),
        DetailFactContent("„Beispiel-Editor“", value: "erledigt", tone: .positive),
        DetailFactContent("„com.example.editor.helper“", value: "erledigt", tone: .positive),
        DetailFactContent("Bildschirmaufnahme-Berechtigung von Fernhilfe",
                          value: "nicht zurückgesetzt: Eintrag hat sich geändert", tone: .critical),
    ])
}

#Preview("LB-3.1 Beobachtungen") {
    ScrollView { DesignGallery(page: .observationsDraft) }
}
