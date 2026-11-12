import GrantryCharts
import SwiftUI

/// Entwurf LB-5.1 (#552): Einstellungen im Lagebild, nativ mit Tokens (Spec § 11 Entscheidung 3) – Tab „Allgemein“ mit
/// Gruppen als Panels und nativen Schaltern, Einrichtung als Prüfzeilen; Tab „Menüleiste“ auf Tokens.
struct SettingsDraftBoard: View {
    var body: some View {
        AreaDraftPage(title: "Lagebild · Einstellungen",
                      subtitle: "Entwurf LB-5.1: Gruppen als Panels mit Peilkopf ohne Ring, native Schalter und Menüs, "
                          + "Einrichtung als Prüfzeilen – feste Beispieldaten") {
            AreaDraftCaption(text: "1 · Allgemein: alles eingerichtet (links), Einrichtung offen und Wachbuch aus (rechts)")
            Self.primary
            AreaDraftCaption(text: "2 · Updates: Prüfung läuft, Update verfügbar, Fehler bei der Installation, Prüfung aus")
            GalleryRow {
                VStack(spacing: InstrumentSpacing.panel) {
                    UpdatesPanel(state: .checking)
                    UpdatesPanel(state: .failed)
                }
                .frame(width: GalleryWindowWidth.settings)
                VStack(spacing: InstrumentSpacing.panel) {
                    UpdatesPanel(state: .available)
                    UpdatesPanel(state: .off)
                }
                .frame(width: GalleryWindowWidth.settings)
            }
            AreaDraftCaption(text: "3 · Einrichtung: wird geprüft (links), Helper wartet auf Genehmigung mit Fehler (rechts)")
            GalleryRow {
                SetupPanel(setup: .checking).frame(width: GalleryWindowWidth.settings)
                SetupPanel(setup: .failed).frame(width: GalleryWindowWidth.settings)
            }
            AreaDraftCaption(text: "4 · Menüleiste: Normalfall (links), kein Element eingeschaltet und Akku fehlt (rechts)")
            GalleryRow {
                MenuBarSettingsWindow(isEmpty: false)
                MenuBarSettingsWindow(isEmpty: true)
            }
        }
    }
}

extension SettingsDraftBoard {
    /// Hauptzustand des Bereichs, auch auf der Galerieseite „Alle Ansichten“ (LB-5.5, #556).
    @ViewBuilder static var primary: some View {
        GalleryRow {
            SettingsGeneralWindow(setup: .complete, updates: .current, watchbookOn: true)
            SettingsGeneralWindow(setup: .missing, updates: .current, watchbookOn: false)
        }
    }
}

// MARK: - Tab Allgemein

/// Tab „Allgemein“ in der heutigen Reihenfolge; „Erneut prüfen“ steht im Kopf der Einrichtung statt unten.
private struct SettingsGeneralWindow: View {
    let setup: SetupState
    let updates: UpdateState
    let watchbookOn: Bool

    var body: some View {
        GalleryWindow(name: "Einstellungen › Allgemein", width: GalleryWindowWidth.settings) {
            SettingsPanel("Darstellung", detail: "Dock und Menüleiste") {
                SettingToggle("Dock-Symbol anzeigen",
                                   note: "Grantry bleibt über die Menüleiste erreichbar, auch ohne Dock-Symbol.",
                                   isOn: .constant(true))
            }
            SetupPanel(setup: setup)
            UpdatesPanel(state: updates)
            SettingsPanel("Netzwerk", detail: "Mitteilungen zu Diensten") {
                SettingRow("Neue Netzwerkdienste melden",
                                note: "Dienste von macOS und beendete Dienste werden nie gemeldet; der Verlauf "
                                    + "enthält alle Änderungen.") {
                    Picker("Neue Netzwerkdienste melden", selection: .constant("exposed")) {
                        Text(verbatim: "Nur von außen erreichbare").tag("exposed")
                        Text(verbatim: "Alle neuen").tag("all")
                        Text(verbatim: "Aus").tag("off")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            WatchbookPanel(isOn: watchbookOn)
            SettingsPanel("Prozesse", detail: "Verwaiste Agenten-Prozesse") {
                SettingToggle(
                    "Hinweis bei vielen verwaisten Agenten-Prozessen",
                    note: "Liest alle 15 Minuten die Prozessliste und meldet sich, sobald mehr als 10 verwaiste "
                        + "Agenten-Prozessbäume oder zusammen mehr als 2 GB Arbeitsspeicher anfallen. Grantry beendet "
                        + "dabei nichts; das geht nur unter Aufräumen › Prozesse nach Bestätigung.",
                    isOn: .constant(true))
            }
            SettingsPanel("Lizenzen", detail: "Komponenten anderer Anbieter") {
                SettingRow("Drittanbieter-Lizenzen",
                                note: "Lizenztexte der Komponenten anderer Anbieter, die Grantry enthält.") {
                    Button("Lizenzen anzeigen …") {}.controlSize(.small)
                }
            }
        }
    }
}

private struct WatchbookPanel: View {
    let isOn: Bool

    var body: some View {
        SettingsPanel("Wachbuch", detail: isOn ? "Aufzeichnung an · 7 Tage" : "Aufzeichnung aus") {
            SettingToggle("Wachbuch führen",
                               note: "Zeichnet alle 10 Sekunden Auslastung, größte Verbraucher, Befunde und "
                                   + "Systemereignisse auf, auch ohne offenes Fenster. Gespeichert nur auf diesem Mac, "
                                   + "7 Tage.",
                               isOn: .constant(isOn))
            SettingToggle("Bei schweren Befunden benachrichtigen",
                               note: isOn
                                   ? "Dauerlast über 10 Minuten, ernster thermischer Zustand oder kritischer "
                                       + "Speicherdruck – höchstens eine Mitteilung je Art und Stunde."
                                   : "Nur wirksam, solange das Wachbuch geführt wird.",
                               isOn: .constant(true)).disabled(!isOn)
        }
    }
}

// MARK: - Einrichtung

/// Zustände der Einrichtung im Entwurf.
enum SetupState {
    case complete, missing, checking, failed
}

/// Einrichtung als Prüfzeilen (Spec § 4.1 `CheckRow`): je Schritt Zustand als Chip, die wichtigste offene Zeile aufgeklappt
/// mit ihrer Aktion; Fehler der Einrichtung als Hinweis `critical` unter den Zeilen.
struct SetupPanel: View {
    let setup: SetupState

    var body: some View {
        SettingsPanel("Einrichtung", detail: SetupSamples.detail(setup),
                           value: SetupSamples.value(setup), finding: SetupSamples.isOpen(setup)) {
            Button("Erneut prüfen") {}.disabled(setup == .checking)
        } content: {
            SetupRows(items: SetupSamples.items(setup), expanded: SetupSamples.expanded(setup))
            if setup == .failed {
                InstrumentNote("Helper konnte nicht installiert werden: Die Genehmigung wurde abgelehnt.",
                               kind: .critical)
            }
        }
    }
}

/// Prüfzeilen mit der Aktion der aufgeklappten Zeile (`CheckRows`); gemeinsam für Einstellungen und Onboarding.
struct SetupRows: View {
    let items: [CheckItem]
    let expanded: String?

    var body: some View {
        CheckRows(items: items, selection: .constant(expanded)) { item in
            SetupSamples.actions(for: item)
        }
    }
}

/// Beispieldaten der Einrichtung mit den Texten von `SetupStep` und `SetupChecklist`.
enum SetupSamples {
    static let fullDiskAccess = "Nötig, um die systemweiten Berechtigungen zu lesen. Nach dem Erteilen erkennt Grantry "
        + "ihn von selbst."
    static let helper = "Liest die Hintergrundobjekte des Systems und führt Aktionen mit Administratorrechten aus."
    static let notifications = "Meldet neue, geänderte und entfernte Einträge, auch wenn das Fenster geschlossen ist."
    static let launchAtLogin = "Startet Grantry beim Anmelden, damit keine Änderung unbemerkt bleibt."

    static func items(_ setup: SetupState) -> [CheckItem] {
        let states: [StatusItem] = switch setup {
        case .complete:
            [ok("Erteilt"), ok("Bereit"), ok("Erlaubt"), ok("Aktiv")]
        case .missing:
            [StatusItem("Nicht erteilt", tone: .critical), StatusItem("Nicht installiert", tone: .critical),
             StatusItem("Noch nicht erlaubt", tone: .finding), StatusItem("Aus", tone: .neutral)]
        case .checking:
            Array(repeating: StatusItem("wird geprüft", tone: .neutral), count: 4)
        case .failed:
            [ok("Erteilt"), StatusItem("Wartet auf Genehmigung", tone: .finding), ok("Erlaubt"), ok("Aktiv")]
        }
        return [
            CheckItem(id: "fullDiskAccess", symbol: "lock.shield", title: "Festplattenvollzugriff",
                      reason: fullDiskAccess, status: states[0]),
            CheckItem(id: "helper", symbol: "wrench.and.screwdriver", title: "Helper", reason: helper,
                      status: states[1],
                      explanation: setup == .failed
                          ? "Unter „Anmeldeobjekte & Erweiterungen“ erlauben; die Genehmigung erfordert ein "
                              + "Administratorkonto." : nil),
            CheckItem(id: "notifications", symbol: "bell", title: "Benachrichtigungen", reason: notifications,
                      status: states[2]),
            CheckItem(id: "launchAtLogin", symbol: "power", title: "Beim Anmelden starten", reason: launchAtLogin,
                      status: states[3]),
        ]
    }

    static func expanded(_ setup: SetupState) -> String? {
        switch setup {
        case .missing: "fullDiskAccess"
        case .failed: "helper"
        case .complete, .checking: nil
        }
    }

    static func isOpen(_ setup: SetupState) -> Bool { setup == .missing || setup == .failed }

    static func detail(_ setup: SetupState) -> String {
        switch setup {
        case .complete: "4 von 4 erledigt"
        case .missing: "0 von 4 erledigt · 2 kritisch"
        case .checking: "Zustand wird gelesen …"
        case .failed: "3 von 4 erledigt"
        }
    }

    static func value(_ setup: SetupState) -> String {
        switch setup {
        case .missing: "4 offen"
        case .failed: "1 offen"
        case .complete, .checking: ""
        }
    }

    /// Aktion je Schritt wie `SetupChecklist.Action`; „Beim Anmelden starten“ als nativer Schalter.
    @ViewBuilder
    static func actions(for item: CheckItem) -> some View {
        switch item.id {
        case "fullDiskAccess" where item.status.tone != .positive: Button("Einstellungen öffnen") {}
        case "helper" where item.status.tone == .critical: Button("Installieren") {}
        case "helper" where item.status.tone == .finding: Button("Genehmigen") {}
        case "notifications" where item.status.tone != .positive: Button("Erlauben …") {}
        case "launchAtLogin":
            Toggle("Beim Anmelden starten", isOn: .constant(item.status.tone == .positive))
                .toggleStyle(.switch).controlSize(.small)
        case "updates":
            Toggle("Täglich nach Updates suchen", isOn: .constant(item.status.tone == .positive))
                .toggleStyle(.switch).controlSize(.small)
        case "baseline" where item.status.tone == .info:
            ProgressSpur(title: "Scan läuft", detail: "Autostart · noch ca. 20 s", fraction: 0.42, tone: .info)
        default: EmptyView()
        }
    }

    private static func ok(_ text: String) -> StatusItem { StatusItem(text, tone: .positive) }
}

// MARK: - Updates

enum UpdateState {
    case current, checking, available, failed, off
}

/// Update-Prüfung: Zustimmung und automatische Installation als Schalter, Datenschutz als Hinweis, letzte Prüfung mit
/// „Jetzt prüfen“; Ergebnis als Hinweiszeile, ein verfügbares Update mit seinen Knöpfen.
private struct UpdatesPanel: View {
    let state: UpdateState

    var body: some View {
        SettingsPanel("Updates", detail: detail, finding: state == .available) {
            SettingToggle("Täglich nach Updates suchen", isOn: .constant(state != .off))
            SettingToggle("Updates automatisch installieren",
                               note: state == .off
                                   ? "Nur mit täglicher Prüfung möglich."
                                   : "Lädt Updates im Hintergrund und installiert sie beim nächsten Beenden. "
                                       + "Standardmäßig ausgeschaltet.",
                               isOn: .constant(false)).disabled(state == .off)
            InstrumentNote("Grantry fragt einmal täglich bei grantry.cstrube.de nach einer neuen Version. Dabei werden "
                + "nur die Version von Grantry, die macOS-Version und die Mac-Architektur übertragen.")
            outcome
            SettingActionLine(lastCheck, runningText: state == .checking ? "Wird geprüft …" : nil) {
                Button("Jetzt prüfen") {}.disabled(state == .checking)
            }
        }
    }

    private var detail: String {
        switch state {
        case .current, .failed: "täglich · Grantry 2026.11.11"
        case .checking: "Prüfung läuft"
        case .available: "Grantry 2026.11.14 verfügbar"
        case .off: "aus"
        }
    }

    private var lastCheck: String {
        state == .off ? "Noch nicht geprüft" : "Zuletzt geprüft: heute, 09:12"
    }

    @ViewBuilder
    private var outcome: some View {
        switch state {
        case .current:
            InstrumentNote("Grantry ist aktuell.")
        case .available:
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                InstrumentNote("Grantry 2026.11.14 ist verfügbar.", kind: .finding)
                HStack(spacing: InstrumentSpacing.group) {
                    Button("Installieren und neu starten") {}
                    Button("DMG-Prüfsumme …") {}
                }
                .controlSize(.small)
            }
        case .failed:
            InstrumentNote("Installation fehlgeschlagen: Die Signatur des Updates passt nicht zur installierten App.",
                           kind: .critical)
        case .checking, .off:
            EmptyView()
        }
    }
}

// MARK: - Tab Menüleiste

/// Tab „Menüleiste“ auf Tokens: Vorschau auf der Mulde, Elemente mit Schalter und Darstellung in einer Spalte, Karten der
/// Übersicht, Kurzbezeichnung und Takt. Die Zeichnung der Elemente ist die echte (`MenuBarMeterRenderer`, TM17).
private struct MenuBarSettingsWindow: View {
    let isEmpty: Bool

    var body: some View {
        GalleryWindow(name: "Einstellungen › Menüleiste", width: GalleryWindowWidth.settings) {
            SettingsPanel("Vorschau", detail: "live mit den aktuellen Messwerten") {
                MenuBarPreviewWell(faces: isEmpty ? [] : MenuBarSamples.shown)
                InstrumentNote("Reihenfolge: in der Menüleiste mit ⌘ ziehen – macOS merkt sie sich.")
            }
            SettingsPanel("Elemente", detail: isEmpty ? "keins eingeschaltet" : "5 von 8 eingeschaltet") {
                ForEach(MenuBarSamples.rows) { row in
                    MenuBarMeterRow(row: row, isOn: !isEmpty && row.isOn, batteryMissing: isEmpty)
                }
            }
            SettingsPanel("Karten der Übersicht", detail: "im Popover „Übersicht“") {
                LazyVGrid(columns: MenuBarSamples.cardColumns, alignment: .leading,
                          spacing: InstrumentSpacing.item) {
                    ForEach(MenuBarSamples.cards, id: \.self) { card in
                        Toggle(card, isOn: .constant(card != "Akku")).toggleStyle(.checkbox)
                            .font(InstrumentFont.body)
                    }
                }
                InstrumentNote("Fehlt eine Messung auf diesem Mac (etwa Akku oder GPU), fehlt auch ihre Karte.")
            }
            SettingsPanel("Anzeige", detail: "Kurzbezeichnung und Takt") {
                SettingToggle("Kurzbezeichnung zeigen (CPU, GPU, RAM …)", isOn: .constant(true))
                SettingRow("Takt", note: "gilt auch im Task-Manager") {
                    Picker("Takt", selection: .constant("1")) {
                        Text(verbatim: "1 s").tag("1")
                        Text(verbatim: "2 s").tag("2")
                        Text(verbatim: "5 s").tag("5")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                InstrumentNote("Gemessen wird nur, was eingeschaltet ist; bei geschlossenem Fenster nur diese Werte.")
            }
        }
    }
}

/// Vorschau der Menüleiste auf der Mulde (`opacity.well`, `radius.block`) statt `.quinary` mit Radius 6.
private struct MenuBarPreviewWell: View {
    let faces: [MenuBarMeterFace]

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: InstrumentSpacing.page) {
            if faces.isEmpty {
                Text(verbatim: "Kein Element eingeschaltet.").font(InstrumentFont.body)
                    .foregroundStyle(.instrumentSecondary)
            } else {
                ForEach(faces.indices, id: \.self) { index in
                    Image(nsImage: MenuBarMeterRenderer.image(for: faces[index],
                                                              increasedContrast: contrast == .increased))
                        .renderingMode(.template)
                        .foregroundStyle(.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InstrumentSpacing.cell)
        .padding(.vertical, InstrumentSpacing.item)
        .background(RoundedRectangle(cornerRadius: InstrumentRadius.block, style: .continuous)
            .fill(.primary.opacity(InstrumentOpacity.well)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Vorschau"))
        .accessibilityValue(Text(verbatim: faces.isEmpty ? "Kein Element eingeschaltet"
            : "Übersicht, CPU 38 %, Arbeitsspeicher 61 %, Netz 3,6 MB/s, Thermik normal"))
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Element der Menüleiste: Schalter mit Name und Hinweis, rechts die Darstellung in einer festen Spalte.
private struct MenuBarMeterRow: View {
    let row: MenuBarSamples.Row
    let isOn: Bool
    let batteryMissing: Bool

    var body: some View {
        let unavailable = batteryMissing && row.id == "battery"
        SettingRow(row.title, note: unavailable ? "Nur auf Macs mit Akku" : row.note,
                        labelsControl: false) {
            HStack(spacing: InstrumentSpacing.cell) {
                Toggle(row.title, isOn: .constant(isOn)).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(unavailable)
                    .accessibilityHint(Text(verbatim: unavailable ? "Nur auf Macs mit Akku" : row.note ?? ""))
                Picker("Darstellung \(row.title)", selection: .constant(row.style)) {
                    Text(verbatim: row.style).tag(row.style)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: MenuBarSamples.styleColumn, alignment: .trailing)
                .disabled(!isOn)
            }
        }
    }
}

/// Feste Werte der Menüleiste wie in den Snapshots von TM17.
enum MenuBarSamples {
    struct Row: Identifiable {
        let id: String
        let title: String
        var note: String?
        let style: String
        var isOn = false
    }

    /// Breite der Spalte „Darstellung“ wie heute.
    static let styleColumn: CGFloat = 150

    static let rows = [
        Row(id: "overview", title: "Übersicht", note: "CPU-Verlauf und Speicherpegel, Popover mit allen Werten",
            style: "Verlauf + Pegel", isOn: true),
        Row(id: "cpu", title: "CPU", style: "Zahl + Verlauf", isOn: true),
        Row(id: "gpu", title: "GPU", style: "Zahl + Verlauf"),
        Row(id: "memory", title: "Arbeitsspeicher", style: "Zahl + Pegel", isOn: true),
        Row(id: "network", title: "Netz", note: "Schnittstelle der Standardroute", style: "Zahl", isOn: true),
        Row(id: "disk", title: "Datenträger", note: "Erstes Laufwerk", style: "Zahl"),
        Row(id: "thermal", title: "Thermik", note: "Zustand laut macOS, Energiesparmodus", style: "Zahl + Pegel",
            isOn: true),
        Row(id: "battery", title: "Akku", style: "Zahl + Pegel"),
    ]

    static let cards = ["CPU", "Kerne", "Prozesse", "GPU", "Arbeitsspeicher", "Datenträger", "Netz", "Thermik", "Akku",
                        "Last und Laufzeit"]
    static let cardColumns = Array(repeating: GridItem(.flexible(), spacing: InstrumentSpacing.group,
                                                       alignment: .leading), count: 3)

    private static let cpu: [Double?] = (0..<30).map { 0.3 + 0.15 * sin(Double($0) / 4) }
    private static let received: [Double?] = (0..<30).map { 0.3 + 0.2 * sin(Double($0) / 3) }
    private static let sent: [Double?] = (0..<30).map { 0.05 + 0.03 * cos(Double($0) / 3) }

    static let shown: [MenuBarMeterFace] = [
        MenuBarMeterFace(tag: nil, lines: [], widest: [], trace: .single(cpu), gauge: .level(0.61), showsNumber: false,
                         showsGraph: true, showsBar: true),
        MenuBarMeterFace(tag: "CPU", lines: ["38 %"], widest: ["100 %"], trace: .single(cpu), gauge: nil,
                         showsNumber: true, showsGraph: true, showsBar: false),
        MenuBarMeterFace(tag: "RAM", lines: ["61 %"], widest: ["100 %"], trace: nil, gauge: .level(0.61),
                         showsNumber: true, showsGraph: false, showsBar: true),
        MenuBarMeterFace(tag: "NETZ", lines: ["↓ 3,6 MB/s", "↑ 48 KB/s"], widest: ["↓ 999 MB/s", "↑ 999 MB/s"],
                         trace: .mirror(upper: received, lower: sent), gauge: nil, showsNumber: true,
                         showsGraph: false, showsBar: false),
        MenuBarMeterFace(tag: "THERMIK", lines: ["Normal"], widest: ["Kritisch"], trace: nil,
                         gauge: .thermometer(0.25), showsNumber: true, showsGraph: false, showsBar: true),
    ]
}

#Preview("LB-5.1 Einstellungen") {
    ScrollView { DesignGallery(page: .settingsDraft) }
}
