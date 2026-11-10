import SwiftUI

/// Inhalt der Ansicht „Belegung“ (Aufräumen › Belegung, TM-15.4, Spec 2026-11-08 § 5.4) als fertige Texte, Anteile und
/// Töne; die Darstellung in ManagerKit rechnet, die App ordnet zu (wie Chip und Verbindungen).
public struct OccupancyBoardContent: Sendable {
    /// Zustandszeile: frei von Kapazität als Urteil, Chips, bereinigbarer Platz als Kenndaten.
    public var verdict: String
    public var finding: Bool
    public var items: [StatusItem]
    public var facts: String
    public var volumes: [OccupancyVolumeContent]
    public var devices: OccupancyDevicesContent
    public var ladder: OccupancyLadderContent
    public var detail: OccupancyDetailContent?
    public var bar: OccupancyBarContent

    public init(verdict: String, finding: Bool, items: [StatusItem], facts: String, volumes: [OccupancyVolumeContent],
                devices: OccupancyDevicesContent, ladder: OccupancyLadderContent, detail: OccupancyDetailContent?,
                bar: OccupancyBarContent) {
        self.verdict = verdict
        self.finding = finding
        self.items = items
        self.facts = facts
        self.volumes = volumes
        self.devices = devices
        self.ladder = ladder
        self.detail = detail
        self.bar = bar
    }
}

/// Panel je Volume: Peilkopf mit dem belegten Anteil, Belegungsband und Legende.
public struct OccupancyVolumeContent: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let value: String
    public let fraction: Double?
    public let parts: [ShareBand.Part]
    public let free: (title: String, value: String)

    public init(id: String, title: String, detail: String, value: String, fraction: Double?, parts: [ShareBand.Part],
                free: (title: String, value: String)) {
        self.id = id
        self.title = title
        self.detail = detail
        self.value = value
        self.fraction = fraction
        self.parts = parts
        self.free = free
    }
}

/// Panel „Datenträger“: je Gerät Name, Anschluss, SMART-Zustand und Kennzahlen (Container, lokale Snapshots).
public struct OccupancyDevicesContent: Sendable {
    public struct Device: Identifiable, Sendable {
        public let id: String
        public let symbol: String
        public let title: String
        public let detail: String
        public let smart: StatusItem
        public let facts: [PanelFact]

        public init(id: String, symbol: String, title: String, detail: String, smart: StatusItem, facts: [PanelFact]) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.detail = detail
            self.smart = smart
            self.facts = facts
        }
    }

    public let detail: String
    public let devices: [Device]
    /// Hinweis, wenn eine Abfrage scheiterte („Angaben unvollständig“); sonst `nil`.
    public let note: String?

    public init(detail: String, devices: [Device], note: String? = nil) {
        self.detail = detail
        self.devices = devices
        self.note = note
    }
}

/// Panel „Ordner“: Kopf, Pfadstufen, Hinweise und je nach Lage Leerzustand, Fortschritt oder Zeilen.
public struct OccupancyLadderContent: Sendable {
    public enum State: Sendable {
        /// Noch nicht gescannt, Scan läuft (ohne früheres Ergebnis) oder gescheitert: Titel, Satz, Symbol.
        case placeholder(title: String, description: String, symbol: String)
        case rows([LadderRow.Content], selection: LadderRow.Content.ID?)
    }

    public let detail: String
    public let value: String
    public let steps: [PathSteps.Step]
    public let notes: [String]
    /// Knopf zum Erteilen des Festplattenvollzugriffs neben den Hinweisen.
    public let offersFullDiskAccess: Bool
    public let state: State

    public init(detail: String, value: String, steps: [PathSteps.Step], notes: [String], offersFullDiskAccess: Bool,
                state: State) {
        self.detail = detail
        self.value = value
        self.steps = steps
        self.notes = notes
        self.offersFullDiskAccess = offersFullDiskAccess
        self.state = state
    }
}

/// Detail rechts: Kopf, Pfad, Kennzahlen, Hinweise (Kategorie, Time Machine), größte Dateien und die zwei Wege.
public struct OccupancyDetailContent: Sendable {
    public struct Hint: Identifiable, Sendable {
        public let title: String
        public let status: StatusItem
        public let text: String

        public var id: String { title }

        public init(title: String, status: StatusItem, text: String) {
            self.title = title
            self.status = status
            self.text = text
        }
    }

    public let title: String
    public let detail: String
    public let value: String
    public let path: String
    public let fields: [(title: String, value: String)]
    public let hints: [Hint]
    public let largestFiles: [PanelFact]
    public let canShowInFinder: Bool
    /// Titel des Sprungs nach Speicher („In Speicher aufräumen“); `nil`, wenn keine Kategorie aufräumt.
    public let cleanupTitle: String?

    public init(title: String, detail: String, value: String, path: String, fields: [(title: String, value: String)],
                hints: [Hint], largestFiles: [PanelFact], canShowInFinder: Bool, cleanupTitle: String?) {
        self.title = title
        self.detail = detail
        self.value = value
        self.path = path
        self.fields = fields
        self.hints = hints
        self.largestFiles = largestFiles
        self.canShowInFinder = canShowInFinder
        self.cleanupTitle = cleanupTitle
    }
}

/// Aktionsleiste unten: Umfang, Fortschritt bzw. Stand, Scannen oder Abbrechen.
public struct OccupancyBarContent: Sendable {
    public let status: String
    public let isScanning: Bool
    public let scanTitle: String
    public let canScan: Bool

    public init(status: String, isScanning: Bool, scanTitle: String, canScan: Bool) {
        self.status = status
        self.isScanning = isScanning
        self.scanTitle = scanTitle
        self.canScan = canScan
    }
}

/// Was gescannt wird: der Benutzerordner (Standard) oder das ganze Startvolume.
public enum OccupancyBoardScope: Hashable, Sendable {
    case home, volume
}

/// Wege aus der Ansicht; alle nur lesend oder in vorhandene, bestätigte Abläufe (Spec § 4.5, Entscheidung O4).
public struct OccupancyBoardActions {
    public var scan: () -> Void
    public var cancel: () -> Void
    /// Zeile gewählt: hinabsteigen oder (ohne Unterordner) im Detail zeigen.
    public var select: (LadderRow.Content.ID) -> Void
    /// Zurück zur Stufe mit dieser Tiefe.
    public var ascend: (Int) -> Void
    public var showInFinder: () -> Void
    public var openCleanup: () -> Void
    public var openFullDiskAccess: () -> Void

    public init(scan: @escaping () -> Void, cancel: @escaping () -> Void,
                select: @escaping (LadderRow.Content.ID) -> Void, ascend: @escaping (Int) -> Void,
                showInFinder: @escaping () -> Void, openCleanup: @escaping () -> Void,
                openFullDiskAccess: @escaping () -> Void) {
        self.scan = scan
        self.cancel = cancel
        self.select = select
        self.ascend = ascend
        self.showInFinder = showInFinder
        self.openCleanup = openCleanup
        self.openFullDiskAccess = openFullDiskAccess
    }

    /// Ohne Wirkung (Vorschau, Bild-Tests).
    public static var none: OccupancyBoardActions {
        OccupancyBoardActions(scan: {}, cancel: {}, select: { _ in }, ascend: { _ in }, showInFinder: {},
                              openCleanup: {}, openFullDiskAccess: {})
    }
}

/// Ansicht „Belegung“ im Lagebild: Zustandszeile; Volumes mit Belegungsband neben den Datenträgern; Ordnerleiter neben
/// dem Detail; unten die Aktionsleiste. Kein Takt: Gezeichnet wird bei neuem Inhalt, der Fortschritt höchstens einmal
/// je Sekunde (Spec § 4.4).
public struct OccupancyBoard: View {
    let content: OccupancyBoardContent
    @Binding var scope: OccupancyBoardScope
    let actions: OccupancyBoardActions

    public init(content: OccupancyBoardContent, scope: Binding<OccupancyBoardScope>, actions: OccupancyBoardActions) {
        self.content = content
        _scope = scope
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: InstrumentSpacing.panel) {
                StatusLine(verdict: content.verdict, finding: content.finding, items: content.items, facts: content.facts)
                HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                    VStack(spacing: InstrumentSpacing.panel) {
                        ForEach(content.volumes) { OccupancyVolumePanel(volume: $0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    OccupancyDevicesPanel(devices: content.devices)
                        .frame(width: InstrumentSize.columnWide)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: InstrumentSpacing.panel) {
                    OccupancyLadderPanel(ladder: content.ladder, select: actions.select, ascend: actions.ascend,
                                         openFullDiskAccess: actions.openFullDiskAccess)
                    OccupancyDetailPanel(detail: content.detail, showInFinder: actions.showInFinder,
                                         openCleanup: actions.openCleanup)
                        .frame(width: InstrumentSize.columnWide)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(InstrumentSpacing.page)
            OccupancyActionBar(bar: content.bar, scope: $scope, scan: actions.scan, cancel: actions.cancel)
        }
        .instrumentBackground()
    }
}

private struct OccupancyVolumePanel: View {
    let volume: OccupancyVolumeContent

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(volume.title, detail: volume.detail, value: volume.value, hue: .diskRead, fraction: volume.fraction)
            ShareBand(parts: volume.parts, hue: .diskRead, label: String(localized: "Belegung \(volume.title)"),
                      free: "\(volume.free.value) \(volume.free.title)")
            ShareBandLegend(parts: volume.parts, hue: .diskRead, free: volume.free)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

private struct OccupancyDevicesPanel: View {
    let devices: OccupancyDevicesContent

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Datenträger"), detail: devices.detail)
            ForEach(devices.devices) { device in
                VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                    HStack(spacing: InstrumentSpacing.cell) {
                        Image(systemName: device.symbol)
                            .font(InstrumentFont.rowIcon)
                            .foregroundStyle(.instrumentSecondary)
                            .frame(width: InstrumentSize.rowIconTall, height: InstrumentSize.rowIconTall)
                            .background(Circle().fill(.primary.opacity(InstrumentOpacity.well)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                            Text(verbatim: device.title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                            Text(verbatim: device.detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: InstrumentSpacing.group)
                        StatusChip(device.smart)
                    }
                    FactRow(facts: device.facts)
                }
                .accessibilityElement(children: .combine)
            }
            if let note = devices.note {
                OccupancyNote(text: note)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

private struct OccupancyLadderPanel: View {
    let ladder: OccupancyLadderContent
    let select: (LadderRow.Content.ID) -> Void
    let ascend: (Int) -> Void
    let openFullDiskAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            PeilHead(String(localized: "Ordner"), detail: ladder.detail, value: ladder.value, identifier: "occupancy.ladder")
            if !ladder.steps.isEmpty {
                PathSteps(steps: ladder.steps, onSelect: ascend)
            }
            ForEach(ladder.notes, id: \.self) { OccupancyNote(text: $0) }
            if ladder.offersFullDiskAccess {
                OccupancyLink(title: String(localized: "Festplattenvollzugriff erteilen …"), action: openFullDiskAccess)
            }
            switch ladder.state {
            case .placeholder(let title, let description, let symbol):
                ContentUnavailableView {
                    Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                } description: {
                    Text(verbatim: description)
                }
                .padding(InstrumentSpacing.empty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .rows(let rows, let selection):
                ChartScrollView(showsIndicators: true) {
                    LazyVStack(spacing: InstrumentSpacing.stack) {
                        ForEach(rows) { row in
                            LadderRow(row, hue: .diskRead, isSelected: row.id == selection) { select(row.id) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

private struct OccupancyDetailPanel: View {
    let detail: OccupancyDetailContent?
    let showInFinder: () -> Void
    let openCleanup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.cell) {
            if let detail {
                PeilHead(detail.title, detail: detail.detail, value: detail.value, identifier: "occupancy.detail")
                Text(verbatim: detail.path)
                    .font(InstrumentFont.code)
                    .foregroundStyle(.instrumentSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                MeasureFieldRow(fields: detail.fields)
                ForEach(detail.hints) { hint in
                    VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                        HStack(spacing: InstrumentSpacing.item) {
                            Text(verbatim: hint.title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                            StatusChip(hint.status)
                        }
                        Text(verbatim: hint.text).font(InstrumentFont.label).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if !detail.largestFiles.isEmpty {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                        Text("Größte Dateien hier").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        ForEach(detail.largestFiles, id: \.self) { file in
                            HStack(spacing: InstrumentSpacing.group) {
                                Text(verbatim: file.title).font(InstrumentFont.label).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: InstrumentSpacing.inline)
                                Text(verbatim: file.value).font(InstrumentFont.label.monospacedDigit())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: InstrumentSpacing.group) {
                    Button(String(localized: "Im Finder zeigen"), action: showInFinder)
                        .disabled(!detail.canShowInFinder)
                    Button(detail.cleanupTitle ?? String(localized: "In Speicher aufräumen"), action: openCleanup)
                        .disabled(detail.cleanupTitle == nil)
                        .help(detail.cleanupTitle == nil ? String(localized: "Keine Kategorie in Speicher räumt hier auf")
                            : String(localized: "Springt zur Kategorie in Aufräumen › Speicher"))
                }
                .font(InstrumentFont.body)
            } else {
                PeilHead(String(localized: "Detail"), identifier: "occupancy.detail")
                Spacer(minLength: 0)
                VStack(spacing: InstrumentSpacing.group) {
                    Image(systemName: "folder").font(InstrumentFont.valueLarge).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Nach dem Scan stehen hier Pfad, Größe und Hinweise zum gewählten Ordner.")
                        .font(InstrumentFont.body).foregroundStyle(.instrumentSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel()
    }
}

private struct OccupancyActionBar: View {
    let bar: OccupancyBarContent
    @Binding var scope: OccupancyBoardScope
    let scan: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            InstrumentSegments(String(localized: "Umfang"), selection: $scope, options: [
                (.home, String(localized: "Benutzerordner")), (.volume, String(localized: "Ganzer Datenträger")),
            ])
            .disabled(bar.isScanning)
            Text(verbatim: bar.status).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
                .lineLimit(1)
                .accessibilityAddTraits(bar.isScanning ? .updatesFrequently : [])
            Spacer(minLength: InstrumentSpacing.group)
            if bar.isScanning {
                Button(String(localized: "Abbrechen"), action: cancel)
                    .accessibilityIdentifier("occupancy.cancel")
            } else {
                Button(bar.scanTitle, action: scan)
                    .disabled(!bar.canScan)
                    .accessibilityIdentifier("occupancy.scan")
            }
        }
        .font(InstrumentFont.body)
        .instrumentBar()
    }
}

/// Verweis in der Textfarbe von `info` statt der Akzentfarbe (§2.5), etwa zu den Systemeinstellungen.
private struct OccupancyLink: View {
    let title: String
    let action: () -> Void

    @Environment(\.self) private var environment

    var body: some View {
        Button(action: action) {
            Text(verbatim: title).font(InstrumentFont.label.weight(.medium)).foregroundStyle(environment.statusTextColor(.info))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}

/// Hinweis (§3.12): `info.circle` mit Satz in Sekundärfarbe.
private struct OccupancyNote: View {
    let text: String

    var body: some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: "info.circle") }
            .font(InstrumentFont.label)
            .foregroundStyle(.instrumentSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
