import GrantryCharts
import SwiftUI

/// Galerieseite der Bausteine für die übrigen Ansichten: Entwurf LB-1.1 (#535), von Christian am 11.11.2026 abgenommen;
/// seit LB-1.2 (#536) aus den zentralen Bausteinen in GrantryCharts gezeichnet. Liste-Detail-Gerüst am Beispiel
/// Berechtigungen, mit festen Beispieldaten ohne persönliche Angaben (erfundene Apps, `com.example`).
struct LagebildBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                Text(verbatim: "Lagebild · Bausteine für die übrigen Ansichten").font(InstrumentFont.display)
                Text(verbatim: "LB-1.2, zentral in GrantryCharts: Liste und Detail, Hinweise, Banner, Häkchenzeilen, "
                    + "Aktionsleiste, Abdeckung und Fortschritt – feste Beispieldaten")
                    .font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
            }
            GalleryCaption(text: "1 · Liste-Detail-Gerüst mit Zustandszeile (Beispiel Berechtigungen, nach App)")
            PermissionsScreen()
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    GalleryCaption(text: "2 · Banner oben im Bereich")
                    BannerSamples()
                    GalleryCaption(text: "3 · Hinweiszeilen und Badges")
                    NoteSamples()
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                    GalleryCaption(text: "4 · Häkchenzeilen mit Aktionsleiste")
                    CheckSamples()
                    GalleryCaption(text: "5 · Abdeckung und Scan-Fortschritt als Spur")
                    ProgressSamples()
                }
            }
            GalleryCaption(text: "6 · Leerzustände im Panel und Detail nach Berechtigung")
            HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                EmptySamples()
                ServiceDetailSample().frame(width: 560)
            }
        }
    }
}

/// Nummerierte Beschriftung eines Abschnitts der Galerie.
private struct GalleryCaption: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(InstrumentFont.label.weight(.semibold)).foregroundStyle(.instrumentSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension InstrumentBadge {
    static let review = InstrumentBadge("prüfen", tone: .finding, spoken: "prüfen, mittlerer Schweregrad")
    static let reviewHigh = InstrumentBadge("prüfen", tone: .critical, spoken: "prüfen, hoher Schweregrad")
    static let new = InstrumentBadge("neu", tone: .neutral)
    static let cleanup = InstrumentBadge("aufräumen", tone: .neutral)
}

// MARK: - 1 Gerüst

private enum PermissionSamples {
    static func item(_ id: String, _ symbol: String, _ title: String, _ detail: String,
                     badges: [InstrumentBadge] = [], finding: Bool = false) -> InstrumentListItem<String> {
        InstrumentListItem(id: id, content: InstrumentRowContent(symbol: symbol, title: title, detail: detail,
                                                                 badges: badges, finding: finding))
    }

    static let sections = [
        InstrumentListSection(id: "befund", title: "Mit Befund", finding: true, items: [
            item("recorder", "record.circle", "Bildschirmrekorder", "Bildschirmaufnahme, Mikrofon, Bedienungshilfen",
                 badges: [.review, .new], finding: true),
            item("sync", "arrow.triangle.2.circlepath", "Ordner-Sync", "Festplattenvollzugriff", badges: [.review],
                 finding: true),
        ]),
        InstrumentListSection(id: "uebrige", title: "Übrige", items: [
            item("meeting", "video", "Videokonferenz", "Kamera, Mikrofon, Bildschirmaufnahme"),
            item("notes", "note.text", "Notizblock", "Erinnerungen, Kalender"),
            item("terminal", "terminal", "Terminal", "Festplattenvollzugriff", badges: [.new]),
            item("old", "questionmark.app.dashed", "Alter Scanner", "Kamera · App nicht mehr vorhanden",
                 badges: [.cleanup]),
        ]),
    ]
}

/// Berechtigungen im Lagebild: Zustandszeile, Umschalter im Inhalt, Auswahlliste links, Detail-Panel rechts.
private struct PermissionsScreen: View {
    @State private var grouping = "app"
    @State private var selection: String? = "recorder"

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            StatusLine(verdict: "2 Apps auffällig", finding: true,
                       items: [StatusItem("2 prüfen", tone: .finding), StatusItem("2 neu seit 7 Tagen", tone: .neutral)],
                       facts: "6 Apps · 12 Berechtigungen · Scan 14:32")
            HStack(spacing: InstrumentSpacing.panel) {
                InstrumentSegments("Gruppierung", selection: $grouping,
                                   options: [("app", "Nach App"), ("service", "Nach Berechtigung")])
                    .frame(width: InstrumentSize.columnNarrow)
                ProgressSpur(title: "Abdeckung vollständig", detail: "alle 3 Quellen gelesen · 14:32", fraction: 1,
                             tone: .positive)
            }
            InstrumentSplit {
                InstrumentList("Apps", count: "6", sections: PermissionSamples.sections, selection: $selection)
            } detail: {
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

/// Detail einer App: Kopf, Angaben, Berechtigungen mit Aktionen.
private struct AppDetailSample: View {
    var body: some View {
        DetailPanel {
            DetailHead(symbol: "record.circle", title: "Bildschirmrekorder", subtitle: "com.example.recorder",
                       items: [StatusItem("prüfen", tone: .finding), StatusItem("neu", tone: .neutral)], finding: true)
            InstrumentNote("Darf den Bildschirm aufnehmen und den Mac fernsteuern – seit 3 Tagen installiert.",
                           kind: .finding)
            DetailGroup("Angaben") {
                DetailEntry("Signatur", value: "Developer ID · Beispiel GmbH (A1B2C3D4E5)", tone: .positive)
                DetailEntry("Pfad", value: "/Applications/Bildschirmrekorder.app", isCode: true)
                DetailEntry("Auf dem Mac", value: "vorhanden")
            }
            DetailGroup("Berechtigungen", count: 3) {
                DetailItem(InstrumentRowContent(symbol: "rectangle.dashed.badge.record", title: "Bildschirmaufnahme",
                                                detail: "Benutzer · geändert am 8. Nov. 2026",
                                                status: StatusItem("erlaubt", tone: .positive))) {
                    EmptyView()
                } actions: {
                    Button("Zurücksetzen …") {}
                    Button("In Systemeinstellungen öffnen") {}
                }
                DetailItem(InstrumentRowContent(symbol: "accessibility", title: "Bedienungshilfen",
                                                detail: "Benutzer · geändert am 8. Nov. 2026", badges: [.review],
                                                status: StatusItem("erlaubt", tone: .positive), finding: true),
                           runningText: "Wird zurückgesetzt …") {
                    InstrumentNote("Steuert andere Apps – nur erlauben, wenn du die App dafür brauchst.",
                                   kind: .finding)
                } actions: {
                    Button("Zurücksetzen …") {}.disabled(true)
                    Button("In Systemeinstellungen öffnen") {}
                }
                DetailItem(InstrumentRowContent(symbol: "mic", title: "Mikrofon",
                                                detail: "System · geändert am 2. Nov. 2026",
                                                status: StatusItem("abgelehnt", tone: .neutral))) {
                    InstrumentNote("Systemweiter Eintrag – Zurücksetzen nur mit Helper.", kind: .locked)
                } actions: {
                    Button("In Systemeinstellungen öffnen") {}
                }
            }
        }
    }
}

// MARK: - 2 Banner

private struct BannerSamples: View {
    var body: some View {
        VStack(spacing: InstrumentSpacing.group) {
            InstrumentBanner("Festplattenvollzugriff fehlt",
                             message: "Ohne ihn bleiben Berechtigungen anderer Benutzer und einige Ordner ungeprüft.",
                             tone: .finding) {
                Button("Systemeinstellungen öffnen") {}
            }
            InstrumentBanner("Update verfügbar: 2026.11.12",
                             message: "Prüfsumme und Signatur sind bestätigt; die Installation startet Grantry neu.",
                             tone: .info) {
                Button("Später") {}
                Button("Installieren …") {}
            }
            InstrumentBanner("3 Einträge in den Papierkorb gelegt",
                             message: "1,4 GB frei. Im Papierkorb lässt sich alles wiederherstellen.", tone: .positive) {
                Button("Papierkorb zeigen") {}
            }
            InstrumentBanner("Zurücksetzen fehlgeschlagen",
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
            InstrumentNote("Einträge aus dem Systemordner zeigt Grantry nur an; ändern lassen sie sich mit dem Helper.")
            InstrumentNote("Schreibgeschützt: Eintrag eines Profils (MDM).", kind: .locked)
            InstrumentNote("Lädt bei jedem Start ein Skript aus dem Benutzerordner nach.", kind: .finding)
            InstrumentNote("Die Datei ist beschädigt und ließ sich nicht lesen.", kind: .critical)
            Divider()
            HStack(spacing: InstrumentSpacing.cell) {
                Text(verbatim: "Badges").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                BadgeChips([.reviewHigh, .review, .new, .cleanup])
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
    @State private var preferences = true
    @State private var caches = true
    @State private var support = false
    @State private var daemon = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                InstrumentSectionHeader(title: "Reste von Alter Scanner", count: 3)
                SelectionCheckRow("Einstellungen", detail: "~/Library/Preferences/com.example.scanner.plist",
                                  size: "12 KB", isOn: $preferences)
                SelectionCheckRow("Caches", detail: "~/Library/Caches/com.example.scanner", size: "1,4 GB",
                                  isOn: $caches, hint: StatusItem("groß", tone: .finding))
                SelectionCheckRow("Programmunterstützung", detail: "~/Library/Application Support/Scanner",
                                  size: "86 MB", isOn: $support, hint: StatusItem("enthält Dokumente", tone: .info))
                SelectionCheckRow("Hintergrunddienst", detail: "/Library/LaunchDaemons/com.example.scanner.plist",
                                  size: "4 KB", isOn: $daemon, lockedReason: "Systemordner – nur mit Helper")
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
            ProgressSpur(title: "Abdeckung unvollständig", detail: "2 von 3 Quellen gelesen · 14:32",
                         fraction: 2.0 / 3, tone: .finding) {
                Button("Details anzeigen …") {}.buttonStyle(.link).font(InstrumentFont.label)
            }
            ProgressSpur(title: "Scan läuft", detail: "Berechtigungen · 142 von 340 Einträgen · noch etwa 20 s",
                         fraction: 0.42, tone: .info)
            ProgressSpur(title: "Erster Scan", detail: "Dauer noch unbekannt", fraction: nil, tone: .info)
            ProgressSpur(title: "Noch nicht geprüft", detail: "kein Scan seit dem Start", fraction: 0,
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
            InstrumentEmptyState(symbol: "hand.raised", title: "Nichts gewählt", message: "Wähle links eine App.")
                .instrumentPanel()
            InstrumentEmptyState(symbol: "magnifyingglass", title: "Keine Treffer",
                                 message: "Nichts passt zu Suche und Filter.")
                .instrumentPanel()
            InstrumentEmptyState(symbol: "clock", title: "Noch kein Scan", message: "Der erste Scan liest alles ein.")
                .instrumentPanel()
        }
        .frame(height: 260)
    }
}

private struct ServiceDetailSample: View {
    var body: some View {
        DetailPanel {
            DetailHead(symbol: "camera", title: "Kamera", subtitle: "kTCCServiceCamera",
                       items: [StatusItem("3 Apps", tone: .neutral)])
            DetailGroup("Apps", count: 3) {
                DetailItem(InstrumentRowContent(symbol: "video", title: "Videokonferenz",
                                                detail: "Benutzer · geändert am 1. Nov. 2026",
                                                status: StatusItem("erlaubt", tone: .positive))) {
                    EmptyView()
                } actions: {
                    Button("Zurücksetzen …") {}
                }
                DetailItem(InstrumentRowContent(symbol: "questionmark.app.dashed", title: "Alter Scanner",
                                                detail: "Benutzer · App nicht mehr vorhanden", badges: [.cleanup],
                                                status: StatusItem("erlaubt", tone: .positive))) {
                    InstrumentNote("Die App fehlt; der Eintrag lässt sich nur für alle Apps zurücksetzen.",
                                   kind: .locked)
                } actions: {
                    Button("Für alle Apps zurücksetzen …") {}
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("LB-1.2 Bausteine") {
    ScrollView { DesignGallery(page: .lagebild) }
}
