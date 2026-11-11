import GrantryCharts
import SwiftUI

/// Galerieseite des Entwurfs LB-1.1 (#535): Liste-Detail-Gerüst am Beispiel Berechtigungen und die neuen Bausteine für
/// die alten Ansichten, mit festen Beispieldaten ohne persönliche Angaben (erfundene Apps, `com.example`).
struct LagebildDraftBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                Text(verbatim: "Lagebild · Bausteine für die übrigen Ansichten").font(InstrumentFont.display)
                Text(verbatim: "Entwurf LB-1.1: Liste und Detail, Hinweise, Banner, Häkchenzeilen, Aktionsleiste, "
                    + "Abdeckung und Fortschritt – feste Beispieldaten")
                    .font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
            DraftCaption(text: "1 · Liste-Detail-Gerüst mit Zustandszeile (Beispiel Berechtigungen, nach App)")
            PermissionsDraftScreen()
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    DraftCaption(text: "2 · Banner oben im Bereich")
                    BannerSamples()
                    DraftCaption(text: "3 · Hinweiszeilen und Badges")
                    NoteSamples()
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    DraftCaption(text: "4 · Häkchenzeilen mit Aktionsleiste")
                    CheckSamples()
                    DraftCaption(text: "5 · Abdeckung und Scan-Fortschritt als Spur")
                    ProgressSamples()
                }
            }
            DraftCaption(text: "6 · Leerzustände im Panel und Detail nach Berechtigung")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                EmptySamples()
                ServiceDetailSample().frame(width: 560)
            }
        }
    }
}

/// Nummerierte Beschriftung eines Abschnitts der Galerie.
private struct DraftCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(InstrumentFont.label.weight(.semibold)).foregroundStyle(.instrumentSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 1 Gerüst

private enum PermissionSamples {
    static let sections = [
        DraftListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            DraftListItem(id: "recorder", symbol: "record.circle", title: "Bildschirmrekorder",
                          detail: "Bildschirmaufnahme, Mikrofon, Bedienungshilfen",
                          badges: [.review, .new], finding: true),
            DraftListItem(id: "sync", symbol: "arrow.triangle.2.circlepath", title: "Ordner-Sync",
                          detail: "Festplattenvollzugriff", badges: [.review], finding: true),
        ]),
        DraftListSection(id: "uebrige", title: "Übrige", items: [
            DraftListItem(id: "meeting", symbol: "video", title: "Videokonferenz",
                          detail: "Kamera, Mikrofon, Bildschirmaufnahme"),
            DraftListItem(id: "notes", symbol: "note.text", title: "Notizblock", detail: "Erinnerungen, Kalender"),
            DraftListItem(id: "terminal", symbol: "terminal", title: "Terminal", detail: "Festplattenvollzugriff",
                          badges: [.new]),
            DraftListItem(id: "old", symbol: "questionmark.app.dashed", title: "Alter Scanner",
                          detail: "Kamera · App nicht mehr vorhanden", badges: [.cleanup]),
        ]),
    ]
}

/// Berechtigungen im Lagebild: Zustandszeile, Umschalter im Inhalt, Auswahlliste links, Detail-Panel rechts.
private struct PermissionsDraftScreen: View {
    @State private var grouping = "app"

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: "2 Apps auffällig", finding: true,
                       items: [StatusItem("2 prüfen", tone: .finding), StatusItem("2 neu seit 7 Tagen", tone: .neutral)],
                       facts: "6 Apps · 12 Berechtigungen · Scan 14:32")
            HStack(spacing: InstrumentSpacing.panel) {
                InstrumentSegments("Gruppierung", selection: $grouping,
                                   options: [("app", "Nach App"), ("service", "Nach Berechtigung")])
                    .frame(width: InstrumentSize.columnNarrow)
                DraftProgressSpur(title: "Abdeckung vollständig", detail: "alle 3 Quellen gelesen · 14:32",
                                  fraction: 1, tone: .positive)
            }
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                DraftList(title: "Apps", count: "6", sections: PermissionSamples.sections, selection: "recorder")
                    .frame(width: InstrumentSize.columnWide)
                AppDetailSample()
            }
            .frame(height: 560)
        }
        .padding(InstrumentSpacing.page)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentBackground()
        .overlay {
            RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous)
                .strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.border)
                .accessibilityHidden(true)
        }
    }
}

/// Detail einer App: Kopf, Angaben, Berechtigungen mit Aktionen, Autostart als Sprungzeile.
private struct AppDetailSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            DraftDetailHead(symbol: "record.circle", title: "Bildschirmrekorder", subtitle: "com.example.recorder",
                            items: [StatusItem("prüfen", tone: .finding), StatusItem("neu", tone: .neutral)],
                            finding: true)
            DraftNote(text: "Darf den Bildschirm aufnehmen und den Mac fernsteuern – seit 3 Tagen installiert.",
                      kind: .finding)
            DraftDetailGroup(title: "Angaben") {
                DraftDetailEntry(key: "Signatur", value: "Developer ID · Beispiel GmbH (A1B2C3D4E5)",
                                 tone: .positive)
                DraftDetailEntry(key: "Pfad", value: "/Applications/Bildschirmrekorder.app", isCode: true)
                DraftDetailEntry(key: "Auf dem Mac", value: "vorhanden")
            }
            DraftDetailGroup(title: "Berechtigungen", count: 3) {
                DraftDetailItem(head: DraftRowHead(symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                                                   detail: "Benutzer · geändert am 8. Nov. 2026",
                                                   status: StatusItem("erlaubt", tone: .positive))) {
                    EmptyView()
                } actions: {
                    Button("Zurücksetzen …") {}
                    Button("In Systemeinstellungen öffnen") {}
                }
                DraftDetailItem(head: DraftRowHead(symbol: "accessibility", title: "Bedienungshilfen",
                                                   detail: "Benutzer · geändert am 8. Nov. 2026", badges: [.review],
                                                   status: StatusItem("erlaubt", tone: .positive), finding: true),
                                isRunning: true) {
                    DraftNote(text: "Steuert andere Apps – nur erlauben, wenn du die App dafür brauchst.",
                              kind: .finding)
                } actions: {
                    Button("Zurücksetzen …") {}.disabled(true)
                    Button("In Systemeinstellungen öffnen") {}
                }
                DraftDetailItem(head: DraftRowHead(symbol: "mic", title: "Mikrofon",
                                                   detail: "System · geändert am 2. Nov. 2026",
                                                   status: StatusItem("abgelehnt", tone: .neutral))) {
                    DraftNote(text: "Systemweiter Eintrag – Zurücksetzen nur mit Helper.", kind: .locked)
                } actions: {
                    Button("In Systemeinstellungen öffnen") {}
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

// MARK: - 2 Banner

private struct BannerSamples: View {
    var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            DraftBanner(title: "Festplattenvollzugriff fehlt",
                        message: "Ohne ihn bleiben Berechtigungen anderer Benutzer und einige Ordner ungeprüft.",
                        tone: .finding) {
                Button("Systemeinstellungen öffnen") {}
            }
            DraftBanner(title: "Update verfügbar: 2026.11.12",
                        message: "Prüfsumme und Signatur sind bestätigt; die Installation startet Grantry neu.",
                        tone: .info) {
                Button("Später") {}
                Button("Installieren …") {}
            }
            DraftBanner(title: "3 Einträge in den Papierkorb gelegt",
                        message: "1,4 GB frei. Im Papierkorb lässt sich alles wiederherstellen.", tone: .positive) {
                Button("Papierkorb zeigen") {}
            }
            DraftBanner(title: "Zurücksetzen fehlgeschlagen",
                        message: "Der Helper hat nicht geantwortet. Es wurde nichts geändert.", tone: .critical) {
                Button("Erneut versuchen") {}
            }
        }
    }
}

// MARK: - 3 Hinweise

private struct NoteSamples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            DraftNote(text: "Einträge aus dem Systemordner zeigt Grantry nur an; ändern lassen sie sich mit dem Helper.")
            DraftNote(text: "Schreibgeschützt: Eintrag eines Profils (MDM).", kind: .locked)
            DraftNote(text: "Lädt bei jedem Start ein Skript aus dem Benutzerordner nach.", kind: .finding)
            DraftNote(text: "Die Datei ist beschädigt und ließ sich nicht lesen.", kind: .critical)
            Divider()
            HStack(spacing: InstrumentSpacing.cell) {
                Text(verbatim: "Badges").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                DraftBadgeChips(badges: [.reviewHigh, .review, .new, .cleanup])
                Spacer()
                Text(verbatim: "Zustände").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                StatusChip("erlaubt", tone: .positive)
                StatusChip("abgelehnt", tone: .neutral)
            }
        }
        .instrumentPanel()
    }
}

// MARK: - 4 Häkchenzeilen

private struct CheckSamples: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                InstrumentSectionHeader(title: "Reste von Alter Scanner", count: 3)
                DraftCheckRow(title: "Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist",
                              size: "12 KB", isOn: true)
                DraftCheckRow(title: "Caches", detail: "~/Library/Caches/com.example.scanner", size: "1,4 GB",
                              isOn: true, hint: StatusItem("groß", tone: .finding))
                DraftCheckRow(title: "Programmunterstützung", detail: "~/Library/Application Support/Scanner",
                              size: "86 MB", isOn: false, hint: StatusItem("enthält Dokumente", tone: .info))
                DraftCheckRow(title: "Hintergrunddienst", detail: "/Library/LaunchDaemons/com.example.scanner.plist",
                              size: "4 KB", isOn: false, lockedReason: "Systemordner – nur mit Helper")
            }
            .padding(InstrumentSpacing.item)
            HStack(spacing: InstrumentSpacing.group) {
                Text(verbatim: "2 von 3 gewählt · 1,4 GB").font(InstrumentFont.body.monospacedDigit())
                Spacer(minLength: InstrumentSpacing.group)
                Button("Keine auswählen") {}
                Button("In den Papierkorb legen …") {}
            }
            .instrumentBar()
        }
        .clipShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous))
        .instrumentPanel(padding: 0)
    }
}

// MARK: - 5 Abdeckung und Fortschritt

private struct ProgressSamples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            DraftProgressSpur(title: "Abdeckung unvollständig", detail: "2 von 3 Quellen gelesen · 14:32",
                              fraction: 2.0 / 3, tone: .finding) {
                Button("Details anzeigen …") {}.buttonStyle(.link).font(InstrumentFont.label)
            }
            DraftProgressSpur(title: "Scan läuft", detail: "Berechtigungen · 142 von 340 Einträgen · noch etwa 20 s",
                              fraction: 0.42, tone: .info)
            DraftProgressSpur(title: "Erster Scan", detail: "Dauer noch unbekannt", fraction: nil, tone: .info)
            DraftProgressSpur(title: "Noch nicht geprüft", detail: "kein Scan seit dem Start", fraction: 0,
                              tone: .neutral) {
                Button("Jetzt scannen") {}.controlSize(.small)
            }
        }
        .instrumentPanel()
    }
}

// MARK: - 6 Leerzustände und Detail nach Berechtigung

private struct EmptySamples: View {
    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            DraftEmptyState(symbol: "hand.raised", title: "Nichts gewählt",
                            message: "Wähle links eine App.")
                .instrumentPanel()
            DraftEmptyState(symbol: "magnifyingglass", title: "Keine Treffer",
                            message: "Nichts passt zu Suche und Filter.")
                .instrumentPanel()
            DraftEmptyState(symbol: "clock", title: "Noch kein Scan",
                            message: "Der erste Scan liest alles ein.")
                .instrumentPanel()
        }
        .frame(height: 260)
    }
}

private struct ServiceDetailSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.bar) {
            DraftDetailHead(symbol: "camera", title: "Kamera", subtitle: "kTCCServiceCamera",
                            items: [StatusItem("3 Apps", tone: .neutral)])
            DraftDetailGroup(title: "Apps", count: 3) {
                DraftDetailItem(head: DraftRowHead(symbol: "video", title: "Videokonferenz",
                                                   detail: "Benutzer · geändert am 1. Nov. 2026",
                                                   status: StatusItem("erlaubt", tone: .positive))) {
                    EmptyView()
                } actions: {
                    Button("Zurücksetzen …") {}
                }
                DraftDetailItem(head: DraftRowHead(symbol: "questionmark.app.dashed", title: "Alter Scanner",
                                                   detail: "Benutzer · App nicht mehr vorhanden", badges: [.cleanup],
                                                   status: StatusItem("erlaubt", tone: .positive))) {
                    DraftNote(text: "Die App fehlt; der Eintrag lässt sich nur für alle Apps zurücksetzen.",
                              kind: .locked)
                } actions: {
                    Button("Für alle Apps zurücksetzen …") {}
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

#Preview("LB-1.1 Bausteine") {
    ScrollView { DesignGallery(page: .lagebildDraft) }
}
