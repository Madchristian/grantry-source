import Foundation

/// Was gescannt wird: der Benutzerordner (Standard) oder das ganze Datenvolume des Startvolumes.
public enum OccupancyScope: Hashable, Sendable {
    case home, volume
}

/// Lage des Scans in der Ansicht „Belegung“.
public enum OccupancyPhase: Hashable, Sendable {
    case idle, scanning, done
    /// Der Scan begann nicht oder brach mit Fehler ab; Satz für den Leerzustand.
    case failed(String)
}

/// Eingaben der Darstellung: alles, was `OccupancyModel` hält, als Wert.
public struct OccupancyState: Sendable {
    public var scope: OccupancyScope = .home
    public var phase: OccupancyPhase = .idle
    public var progress: OccupancyProgress?
    public var inventory: VolumeInventory?
    public var tree: OccupancyTree?
    public var cleanable: OccupancyCleanable?
    public var hints: OccupancyHints?
    /// Ordner (`id` im Baum) von unterhalb der Wurzel bis zu dem, in dem man steht.
    public var trail: [Int] = []
    /// Gewählte Zeile ohne Unterordner (`id` oder `OccupancyPresentation.filesRowID`); sonst `nil`.
    public var selection: Int?
    /// Time-Machine-Status je Pfad (Schreibweise des Baums); fehlt einer, wird er gerade gelesen.
    public var timeMachine: [String: TimeMachineFolderStatus] = [:]
    public var isFullDiskAccessMissing = false
    /// Orte, die der Scan ohne Festplattenvollzugriff ausgelassen hat.
    public var excludedPlaces = 0
    public var scannedAt: Date?
    public var scanDuration: Duration?
    public var home: String

    public init(home: String) {
        self.home = home
    }
}

/// Ansicht „Belegung“ (Aufräumen › Belegung, TM-15.4, Spec 2026-11-08 § 5.4): Zustandszeile, Volumes mit Belegungsband,
/// Datenträger, Ordnerleiter und Detail als fertige Texte; Töne und Bausteine ordnet die App zu.
public struct OccupancyPresentation: Sendable {
    public enum Tone: Hashable, Sendable {
        case positive, info, neutral, critical
    }

    public struct Chip: Hashable, Sendable {
        public let text: String
        public let tone: Tone
    }

    public struct Fact: Hashable, Sendable {
        public let title: String
        public let value: String
    }

    /// Teil des Belegungsbands; `level` von 0 (fest) bis 4 (flüchtig).
    public struct BandPart: Hashable, Sendable {
        public let id: String
        public let title: String
        public let value: String
        public let fraction: Double
        public let level: Int
    }

    public struct Volume: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let value: String
        public let fraction: Double?
        public let parts: [BandPart]
        public let free: String
    }

    public struct Device: Identifiable, Sendable {
        public let id: String
        public let isInternal: Bool
        public let title: String
        public let detail: String
        public let smart: Chip
        public let facts: [Fact]
    }

    public struct Devices: Sendable {
        public let detail: String
        public let devices: [Device]
        public let note: String?
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case folder, files, otherVolume, network, cloud, more
        }

        public let id: Int
        public let kind: Kind
        public let name: String
        public let value: String
        public let fraction: Double?
        public let chip: Chip?
        public let isDescendable: Bool
        public let isMuted: Bool
        public let accessibilityLabel: String
    }

    public struct Step: Hashable, Sendable {
        /// Tiefe ab der Wurzel (0).
        public let depth: Int
        public let title: String
    }

    public enum LadderState: Sendable {
        case placeholder(title: String, description: String, symbol: String)
        case rows([Row], selection: Int?)
    }

    public struct Ladder: Sendable {
        public let detail: String
        public let value: String
        public let steps: [Step]
        public let notes: [String]
        public let offersFullDiskAccess: Bool
        public let state: LadderState
    }

    public struct Hint: Hashable, Sendable {
        public let title: String
        public let status: Chip
        public let text: String
    }

    public struct Detail: Sendable {
        public let title: String
        public let detail: String
        public let value: String
        /// Pfad zum Anzeigen (Firmlink, `~` für den Benutzerordner).
        public let displayPath: String
        /// Pfad für den Finder.
        public let path: String
        public let fields: [Fact]
        public let hints: [Hint]
        public let largestFiles: [Fact]
        /// Kategorie in Speicher, zu der „In Speicher …“ springt; `nil` ohne eigene Kategorie.
        public let categoryID: String?
        public let cleanupTitle: String?
    }

    public struct Bar: Sendable {
        public let status: String
        public let isScanning: Bool
        public let scanTitle: String
        public let canScan: Bool
    }

    /// Zeile „Dateien direkt in …“ (ihr Ordner ist der aktuelle).
    public static let filesRowID = -1
    /// Sammelzeile für Unterordner jenseits von `maximumRows`.
    public static let moreRowID = -2
    /// Höchstens so viele Unterordner als Zeilen; der Rest als Sammelzeile (Spec § 4.4: Tabellen klein halten).
    public static let maximumRows = 200
    static let largestFilesShown = 3
    static let maximumNameLength = 120

    public let verdict: String
    public let finding: Bool
    public let items: [Chip]
    public let facts: String
    public let volumes: [Volume]
    public let devices: Devices
    public let ladder: Ladder
    public let detail: Detail?
    public let bar: Bar

    /// - Parameter findings: Befunde der Lagezeile (`TaskManagerModel.findings`); laufende Datenträger-Befunde setzen den
    ///   Befund-Punkt der Zustandszeile wie in den übrigen Tabs.
    public init(_ state: OccupancyState, findings: [SystemFinding] = [], now: Date, calendar: Calendar = .current) {
        let texts = OccupancyTexts(now: now, calendar: calendar)
        let startup = Self.startupContainer(state.inventory)
        let usage = startup?.container.usage
        verdict = usage.map { "\(AppTexts.formattedSize($0.availableBytes)) frei von \(AppTexts.formattedSize($0.totalBytes))" }
            ?? (state.inventory == nil ? "Belegung" : "Startvolume nicht lesbar")
        finding = findings.contains { $0.isOngoing && $0.kind.isStorage }
        items = Self.items(state)
        facts = [usage?.purgeableBytes.flatMap { $0 > 0 ? "macOS kann \(AppTexts.formattedSize($0)) zusätzlich freigeben" : nil },
                 state.scannedAt.map { "gescannt \(texts.moment($0))" }].compactMap(\.self).joined(separator: " · ")
        volumes = Self.volumes(state, startupID: startup?.container.id)
        devices = Self.devices(state.inventory, startupDeviceID: startup?.device.id, texts: texts)
        let navigation = OccupancyNavigation(state)
        ladder = Self.ladder(state, navigation: navigation)
        detail = navigation.map { Self.detail(state, navigation: $0, texts: texts) }
        bar = Self.bar(state, texts: texts)
    }
}

// MARK: - Zustandszeile

extension OccupancyPresentation {
    static func items(_ state: OccupancyState) -> [Chip] {
        var items: [Chip] = []
        switch state.phase {
        case .idle where state.tree == nil: items.append(Chip(text: "Noch nicht gescannt", tone: .neutral))
        case .scanning: items.append(Chip(text: "Scan läuft", tone: .info))
        case .failed: items.append(Chip(text: "Scan gescheitert", tone: .neutral))
        default: break
        }
        if let cleanable = state.cleanable?.total, cleanable > 0 {
            items.append(Chip(text: "\(AppTexts.formattedSize(cleanable)) über Speicher aufräumbar", tone: .info))
        }
        if let uncaptured = state.tree?.root.uncapturedCount, uncaptured > 0 {
            items.append(Chip(text: OccupancyTexts.places(uncaptured) + " nicht erfasst", tone: .neutral))
        }
        return items
    }
}

// MARK: - Volumes und Datenträger

extension OccupancyPresentation {
    /// Der Container mit dem Startvolume (System- oder Datenvolume an `/` bzw. `/System/Volumes/Data`).
    static func startupContainer(_ inventory: VolumeInventory?) -> (device: StorageDevice, container: APFSContainer)? {
        for device in inventory?.devices ?? [] {
            for container in device.containers where container.volumes.contains(where: {
                $0.mountPoint == "/" || $0.mountPoint == MountedVolume.dataVolumePrefix
            }) {
                return (device, container)
            }
        }
        return nil
    }

    static func volumes(_ state: OccupancyState, startupID: String?) -> [Volume] {
        (state.inventory?.devices ?? []).flatMap { device in
            device.containers.compactMap { container -> Volume? in
                guard let usage = container.usage, usage.totalBytes > 0 else { return nil }
                let title = (container.volumes.first { $0.role == .system } ?? container.volumes.first { $0.mountPoint != nil })?
                    .name ?? container.id
                let encrypted = container.volumes.first { $0.role == .data } ?? container.volumes.first
                let detail = ["APFS", device.isInternal == true ? "intern" : device.busProtocol ?? "extern",
                              encrypted?.isEncrypted == true ? "verschlüsselt" : "nicht verschlüsselt"].joined(separator: " · ")
                let used = Double(usage.usedBytes) / Double(usage.totalBytes)
                return Volume(id: container.id, title: title, detail: detail,
                              value: "\(Int((used * 100).rounded())) % belegt", fraction: used,
                              parts: bandParts(state, container: container, usage: usage,
                                               isStartup: container.id == startupID),
                              free: AppTexts.formattedSize(usage.availableBytes))
            }
        }
    }

    /// Teile des Belegungsbands. Ohne Scan: System (Volumes außer Daten), Daten, bereinigbar. Mit Scan des
    /// Benutzerordners: System und weitere, Benutzerordner, über Speicher aufräumbar, bereinigbar. Mit Scan des ganzen
    /// Datenträgers: System, Apps, Benutzer, über Speicher aufräumbar, bereinigbar. Überschneidungen (bereinigbare Dateien
    /// im Benutzerordner) schneidet das Band am Ende ab.
    static func bandParts(_ state: OccupancyState, container: APFSContainer, usage: VolumeUsage,
                          isStartup: Bool) -> [BandPart] {
        let total = Double(usage.totalBytes), used = usage.usedBytes, purgeable = usage.purgeableBytes ?? 0
        func part(_ id: String, _ title: String, _ bytes: Int64, level: Int) -> BandPart {
            BandPart(id: id, title: title, value: AppTexts.formattedSize(max(0, bytes)), fraction: Double(max(0, bytes)) / total,
                     level: level)
        }
        let purgeablePart = purgeable > 0 ? [part("purgeable", "bereinigbar", purgeable, level: 4)] : []
        guard isStartup, let tree = state.tree else {
            guard isStartup else { return [part("data", "Daten, nicht aufgeteilt", used - purgeable, level: 1)] + purgeablePart }
            let system = container.volumes.filter { $0.role != .data }.reduce(0) { $0 + $1.usedBytes }
            return [part("system", "System", system, level: 0),
                    part("data", "Daten, nicht aufgeteilt", used - system - purgeable, level: 1)] + purgeablePart
        }
        let cleanable = state.cleanable?.total ?? 0
        let complete = tree.root.isComplete
        switch state.scope {
        case .home:
            let home = tree.root.allocatedBytes
            return [part("rest", "System und weitere", used - home - purgeable, level: 0),
                    part("home", complete ? "Benutzerordner" : "Benutzerordner (erfasst)", home - cleanable, level: 2),
                    part("cleanable", "über Speicher aufräumbar", cleanable, level: 3)] + purgeablePart
        case .volume:
            let apps = tree.folder(atPath: tree.rootPath + "/Applications")?.allocatedBytes ?? 0
            let users = tree.folder(atPath: tree.rootPath + "/Users")?.allocatedBytes ?? 0
            return [part("system", "System", used - apps - users - purgeable, level: 0),
                    part("apps", "Apps", apps, level: 1),
                    part("users", complete ? "Benutzer" : "Benutzer (erfasst)", users - cleanable, level: 2),
                    part("cleanable", "über Speicher aufräumbar", cleanable, level: 3)] + purgeablePart
        }
    }

    static func devices(_ inventory: VolumeInventory?, startupDeviceID: String?, texts: OccupancyTexts) -> Devices {
        let devices = (inventory?.devices ?? []).map { device in
            let kind = device.isSolidState.map { $0 ? "SSD" : "Festplatte" }
            let detail = [device.busProtocol, kind, device.sizeBytes.map(AppTexts.formattedSize)].compactMap(\.self)
                .joined(separator: " · ")
            var facts = device.containers.map { container in
                Fact(title: "Container", value: "\(container.id), \(OccupancyTexts.count(container.volumes.count, "Volume", "Volumes"))")
            }
            if device.id == startupDeviceID {
                facts.append(Fact(title: "Lokale Snapshots", value: texts.snapshots(inventory?.localSnapshots)))
            }
            let tone: Tone = switch device.smartStatus {
            case .verified: .positive
            case .failing: .critical
            case .notSupported, .unknown: .neutral
            }
            return Device(id: device.id, isInternal: device.isInternal == true, title: device.name ?? device.id,
                          detail: detail.isEmpty ? device.id : detail,
                          smart: Chip(text: "SMART \(device.smartStatus.title)", tone: tone), facts: facts)
        }
        let internalCount = devices.filter(\.isInternal).count, externalCount = devices.count - internalCount
        let detail = inventory == nil ? "werden gelesen …"
            : [internalCount > 0 ? "\(internalCount) intern" : nil, externalCount > 0 ? "\(externalCount) extern" : nil]
                .compactMap(\.self).joined(separator: " · ")
        let note = inventory.map { $0.isComplete ? nil : "Einige Angaben fehlen – eine Abfrage scheiterte oder dauerte zu lange." }
            ?? nil
        return Devices(detail: detail, devices: devices, note: note)
    }
}

// MARK: - Ordnerleiter

/// Wo man im Baum steht: der aktuelle Ordner, sein Weg und die gewählte Zeile.
struct OccupancyNavigation {
    let tree: OccupancyTree
    /// Wurzel bis aktueller Ordner.
    let trail: [OccupancyFolder]
    let current: OccupancyFolder
    let subfolders: [OccupancyFolder]
    /// Bytes der Dateien direkt im aktuellen Ordner.
    let files: Int64
    let selection: Int?

    init?(_ state: OccupancyState) {
        guard let tree = state.tree else { return nil }
        var trail = [tree.root]
        for id in state.trail {
            guard let next = tree.subfolders(of: trail[trail.count - 1]).first(where: { $0.id == id }) else { break }
            trail.append(next)
        }
        self.tree = tree
        self.trail = trail
        current = trail[trail.count - 1]
        subfolders = tree.subfolders(of: current)
        let files = max(0, current.allocatedBytes - subfolders.reduce(0) { $0 + $1.allocatedBytes })
        self.files = files
        let ids = Set(subfolders.prefix(OccupancyPresentation.maximumRows).map(\.id))
        selection = state.selection.flatMap { $0 == OccupancyPresentation.filesRowID && files > 0 || ids.contains($0) ? $0 : nil }
    }

    /// Ordner im Detail: die gewählte Zeile, sonst der aktuelle.
    var focused: OccupancyFolder? {
        selection.flatMap { id in subfolders.first { $0.id == id } }
    }
}

extension OccupancyPresentation {
    static func ladder(_ state: OccupancyState, navigation: OccupancyNavigation?) -> Ladder {
        let scope = state.scope == .home ? "Benutzerordner" : "Ganzer Datenträger"
        var notes: [String] = []
        if state.excludedPlaces > 0 {
            notes.append("""
                Ohne Festplattenvollzugriff liest Grantry \(OccupancyTexts.places(state.excludedPlaces, protected: true)) \
                nicht (Schreibtisch, Dokumente, Downloads, iCloud Drive …), damit macOS nicht nachfragt. Größen darüber \
                sind Untergrenzen.
                """)
        }
        guard let navigation else {
            let placeholder: LadderState = switch state.phase {
            case .scanning:
                .placeholder(title: "Scan läuft", description: OccupancyTexts.progress(state.progress, long: true)
                    + " Gedrosselt, damit der Mac flüssig bleibt.", symbol: "hourglass")
            case .failed(let reason):
                .placeholder(title: "Scan nicht möglich", description: reason, symbol: "exclamationmark.triangle")
            case .idle, .done:
                .placeholder(title: "Noch nicht gescannt", description: """
                    Grantry liest auf Abruf, wie viel Platz deine Ordner belegen – nur lesend. Aufgeräumt wird über \
                    Speicher, nach deiner Bestätigung.
                    """, symbol: "folder.badge.questionmark")
            }
            return Ladder(detail: state.phase == .scanning ? "\(scope) · Scan läuft" : scope, value: "", steps: [],
                          notes: notes, offersFullDiskAccess: state.isFullDiskAccessMissing, state: placeholder)
        }
        let tree = navigation.tree, root = tree.root
        let detail = [scope, OccupancyTexts.count(root.fileCount, "Datei", "Dateien"),
                      root.uncapturedCount > 0 ? OccupancyTexts.places(root.uncapturedCount) + " nicht erfasst" : nil]
            .compactMap(\.self).joined(separator: " · ")
        let steps = navigation.trail.enumerated().map { depth, folder in
            Step(depth: depth, title: depth == 0 ? rootTitle(state) : displayName(folder.name))
        }
        let rows = rows(state, navigation: navigation)
        if rows.contains(where: { $0.kind == .network }) {
            notes.append("Netzlaufwerke liest Grantry nicht; sie bleiben ausgelassen.")
        }
        return Ladder(detail: detail, value: OccupancyTexts.size(navigation.current), steps: steps, notes: notes,
                      offersFullDiskAccess: state.isFullDiskAccessMissing && root.uncapturedCount > 0,
                      state: .rows(rows, selection: navigation.selection))
    }

    static func rootTitle(_ state: OccupancyState) -> String {
        guard state.scope == .volume else { return "Benutzerordner" }
        return startupContainer(state.inventory)?.container.volumes.first { $0.role == .system }?.name ?? "Datenträger"
    }

    static func displayName(_ name: String) -> String {
        DisplayText.singleLine(name, maximumLength: maximumNameLength)
    }

    static func rows(_ state: OccupancyState, navigation: OccupancyNavigation) -> [Row] {
        let tree = navigation.tree, current = navigation.current
        let parentName = navigation.trail.count == 1 ? rootTitle(state) : displayName(current.name)
        let currentCategory = state.hints?.hint(forPath: tree.path(of: current)).category
        func share(_ bytes: Int64) -> Double? {
            current.allocatedBytes > 0 ? Double(bytes) / Double(current.allocatedBytes) : nil
        }
        func label(_ name: String, _ value: String, _ fraction: Double?, _ chip: Chip?) -> String {
            [name, value, fraction.map { "\(OccupancyTexts.percent($0)) von \(parentName)" }, chip?.text]
                .compactMap(\.self).joined(separator: ", ")
        }
        var rows = navigation.subfolders.prefix(maximumRows).map { folder in
            let name = displayName(folder.name)
            let (kind, chip) = rowKind(folder, path: tree.path(of: folder), hints: state.hints, parent: currentCategory)
            let measured = kind == .folder || kind == .cloud
            let fraction = measured && !(folder.state.isUncaptured && folder.allocatedBytes == 0)
                ? share(folder.allocatedBytes) : nil
            let value = fraction == nil ? "–" : OccupancyTexts.size(folder)
            return Row(id: folder.id, kind: kind, name: name, value: value, fraction: fraction, chip: chip,
                       isDescendable: kind == .folder && folder.subfolderCount > 0,
                       isMuted: fraction == nil || kind == .cloud,
                       accessibilityLabel: label(name, value, fraction, chip))
        }
        let rest = navigation.subfolders.dropFirst(maximumRows)
        if !rest.isEmpty {
            let bytes = rest.reduce(0) { $0 + $1.allocatedBytes }
            let name = "\(OccupancyTexts.count(rest.count, "weiterer Ordner", "weitere Ordner"))"
            rows.append(Row(id: moreRowID, kind: .more, name: name, value: AppTexts.formattedSize(bytes), fraction: share(bytes),
                            chip: nil, isDescendable: false, isMuted: true,
                            accessibilityLabel: label(name, AppTexts.formattedSize(bytes), share(bytes), nil)))
        }
        if navigation.files > 0 {
            let name = "Dateien direkt in \(parentName)", value = AppTexts.formattedSize(navigation.files)
            let row = Row(id: filesRowID, kind: .files, name: name, value: value, fraction: share(navigation.files), chip: nil,
                          isDescendable: false, isMuted: false,
                          accessibilityLabel: label(name, value, share(navigation.files), nil))
            // Nach Größe einsortiert, wie die Ordner.
            let index = rows.firstIndex { $0.kind == .folder && ($0.fraction ?? 0) < (row.fraction ?? 0) } ?? rows.count
            rows.insert(row, at: index)
        }
        return rows
    }

    /// Art und Chip einer Zeile: Erfassung vor Kategorie. Die Kategorie nur, wenn sie von der des aktuellen Ordners
    /// abweicht; lässt die Kategorie des aktuellen Ordners den Eintrag bewusst aus, „bleibt“.
    static func rowKind(_ folder: OccupancyFolder, path: String, hints: OccupancyHints?,
                        parent: StorageCategory?) -> (Row.Kind, Chip?) {
        switch folder.state {
        case .otherVolume(isLocal: false): return (.network, Chip(text: "Netzlaufwerk, ausgelassen", tone: .neutral))
        case .otherVolume: return (.otherVolume, Chip(text: "anderes Volume", tone: .neutral))
        case .cloudOnly: return (.cloud, Chip(text: "nur in iCloud", tone: .neutral))
        case .uncaptured where folder.allocatedBytes == 0:
            return (.folder, Chip(text: "nicht erfasst", tone: .neutral))
        case .uncaptured:
            return (.folder, Chip(text: "teils nicht erfasst", tone: .neutral))
        case .complete where !folder.isComplete:
            return (.folder, Chip(text: "teils nicht erfasst", tone: .neutral))
        case .complete:
            let category = hints?.hint(forPath: path).category
            guard category?.id != parent?.id else { return (.folder, nil) }
            guard let category else { return (.folder, Chip(text: "bleibt", tone: .neutral)) }
            return (.folder, Chip(text: category.title, tone: category.risk == .reportOnly ? .neutral : .info))
        }
    }
}

// MARK: - Detail und Leiste

extension OccupancyPresentation {
    static func detail(_ state: OccupancyState, navigation: OccupancyNavigation, texts: OccupancyTexts) -> Detail {
        let tree = navigation.tree
        let parentName = navigation.trail.count == 1 ? rootTitle(state) : displayName(navigation.current.name)
        if navigation.selection == filesRowID {
            let path = tree.path(of: navigation.current)
            return Detail(title: "Dateien", detail: "direkt in \(parentName)", value: AppTexts.formattedSize(navigation.files),
                          displayPath: displayPath(path, home: state.home), path: path,
                          fields: [Fact(title: "Anteil", value: OccupancyTexts.percent(
                              Double(navigation.files) / Double(max(1, navigation.current.allocatedBytes))))],
                          hints: [], largestFiles: largestFiles(navigation.current), categoryID: nil, cleanupTitle: nil)
        }
        let folder = navigation.focused ?? navigation.current
        let isCurrent = navigation.focused == nil
        let isRoot = folder.id == tree.root.id
        let path = tree.path(of: folder)
        // Ein ausgelassenes Volume ist nie gemessen: Größe und Zähler unbekannt, keine Kategorie und kein Time-Machine-Status.
        let leftOut = leftOutChip(folder)
        let hint = leftOut == nil ? state.hints?.hint(forPath: path) ?? .empty : .empty
        let uncaptured = (folder.state.isUncaptured && folder.allocatedBytes == 0) || leftOut != nil
        let parent = isCurrent ? tree.parent(of: folder) : navigation.current
        let share = parent.map { parent in
            "\(OccupancyTexts.percent(Double(folder.allocatedBytes) / Double(max(1, parent.allocatedBytes)))) von "
                + (parent.id == tree.root.id ? rootTitle(state) : displayName(parent.name))
        }
        var fields = uncaptured ? [Fact(title: "Dateien", value: "–"), Fact(title: "Unterordner", value: "–")] : [
            Fact(title: "Dateien", value: folder.fileCount.formatted()),
            Fact(title: "Unterordner", value: folder.subfolderCount.formatted()),
        ]
        let modification = leftOut == nil ? folder.newestModification ?? folder.modification : nil
        fields.append(Fact(title: "Letzte Änderung", value: modification.map(texts.moment) ?? "–"))
        let cleanable = state.cleanable?.bytes(in: folder, of: tree) ?? 0
        if cleanable > 0 { fields.append(Fact(title: "davon aufräumbar", value: AppTexts.formattedSize(cleanable))) }
        var hints: [Hint] = []
        if !folder.isComplete || uncaptured {
            hints.append(Hint(title: "Erfassung",
                              status: leftOut ?? Chip(text: uncaptured ? "nicht erfasst" : "teils nicht erfasst", tone: .neutral),
                              text: coverageText(folder, excluded: state.excludedPlaces > 0)))
        }
        if let category = hint.category {
            hints.append(Hint(title: "Kategorie", status: Chip(text: category.title,
                                                               tone: category.risk == .reportOnly ? .neutral : .info),
                              text: categoryText(category)))
        }
        if !uncaptured { hints.append(timeMachineHint(state.timeMachine[path], candidate: hint.timeMachineCandidate, home: state.home)) }
        return Detail(title: isRoot ? rootTitle(state) : displayName(folder.name),
                      detail: (["Ordner"] + [leftOut != nil ? "ausgelassen" : uncaptured ? "nicht erfasst" : share]
                          .compactMap(\.self)).joined(separator: " · "),
                      value: uncaptured ? "–" : OccupancyTexts.size(folder), displayPath: displayPath(path, home: state.home),
                      path: MountedVolume.firmlinkedPath(path), fields: fields, hints: hints,
                      largestFiles: largestFiles(folder), categoryID: hint.category?.id,
                      cleanupTitle: hint.category.map { $0.risk == .reportOnly ? "In Speicher zeigen" : "In Speicher aufräumen" })
    }

    static func largestFiles(_ folder: OccupancyFolder) -> [Fact] {
        folder.largestFiles.prefix(largestFilesShown).map {
            Fact(title: displayName($0.name), value: AppTexts.formattedSize($0.allocatedBytes))
        }
    }

    /// Chip eines ausgelassenen Volumes wie in der Ordnerleiter; sonst `nil`.
    static func leftOutChip(_ folder: OccupancyFolder) -> Chip? {
        guard case .otherVolume = folder.state else { return nil }
        return rowKind(folder, path: "", hints: nil, parent: nil).1
    }

    static func coverageText(_ folder: OccupancyFolder, excluded: Bool) -> String {
        switch folder.state {
        case .otherVolume(isLocal: false): "Netzlaufwerke liest Grantry nicht; die Größe ist unbekannt."
        case .otherVolume:
            "Hier ist ein anderes Volume eingehängt. Der Scan bleibt auf einem Volume; die Größe ist unbekannt."
        case .uncaptured(.excluded):
            "Ohne Festplattenvollzugriff liest Grantry diesen Ort nicht, damit macOS nicht nachfragt."
        case .uncaptured(.permissionDenied):
            "Grantry darf diesen Ordner nicht lesen" + (excluded ? " – mit Festplattenvollzugriff vielleicht schon." : ".")
        case .uncaptured(.changed): "Der Ordner wurde während des Scans ersetzt; die Größe enthält das Gelesene."
        case .uncaptured: "Einige Einträge ließen sich nicht lesen; die Größe enthält das Lesbare."
        default: "\(OccupancyTexts.places(folder.uncapturedCount)) darunter nicht erfasst; die Größe ist eine Untergrenze."
        }
    }

    static func categoryText(_ category: StorageCategory) -> String {
        let risk = switch category.risk {
        case .low: "Risiko gering · über Speicher aufräumbar"
        case .medium: "Risiko mittel · über Speicher aufräumbar"
        case .reportOnly: "nur Bericht · Speicher nennt die Größe, räumt aber nicht auf"
        }
        return "\(risk). \(category.summary)"
    }

    static func timeMachineHint(_ status: TimeMachineFolderStatus?, candidate: TimeMachineCandidate?, home: String) -> Hint {
        let suggestion = candidate.map {
            "Vorschlag: aus Time Machine ausnehmen (\($0.title), Risiko \($0.risk == .low ? "gering" : "mittel"))."
        }
        guard let status else {
            return Hint(title: "Time Machine", status: Chip(text: "wird geprüft …", tone: .neutral), text: suggestion ?? "")
        }
        switch status.state {
        case .included:
            return Hint(title: "Time Machine", status: Chip(text: "wird gesichert", tone: .neutral),
                        text: suggestion ?? "Time Machine sichert diesen Ordner.")
        case .excluded:
            let folder = status.excludedFolder.map { displayPath($0, home: home) }
            return Hint(title: "Time Machine", status: Chip(text: "ausgenommen", tone: .info),
                        text: folder.map { "Ausgenommen über \($0)." } ?? "Time Machine sichert diesen Ordner nicht.")
        case .unknown:
            return Hint(title: "Time Machine", status: Chip(text: "unbekannt", tone: .neutral),
                        text: suggestion ?? "Der Sicherungsstatus ließ sich nicht lesen.")
        }
    }

    /// Firmlink-Schreibweise, Benutzerordner als `~`.
    static func displayPath(_ path: String, home: String) -> String {
        let path = MountedVolume.firmlinkedPath(path)
        guard RawPath.isPath(path, atOrBelow: home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func bar(_ state: OccupancyState, texts: OccupancyTexts) -> Bar {
        let scanTitle = state.tree == nil ? "Scannen" : "Erneut scannen"
        let status: String = switch state.phase {
        case .scanning: OccupancyTexts.progress(state.progress, long: false)
        case .failed(let reason): reason
        case .idle, .done:
            state.scannedAt.map { date in
                "Gescannt \(texts.moment(date))" + (state.scanDuration.map { " in \(OccupancyTexts.duration($0))" } ?? "")
            } ?? "Nur lesend, gedrosselt"
        }
        return Bar(status: status, isScanning: state.phase == .scanning, scanTitle: scanTitle,
                   canScan: state.phase != .scanning)
    }
}

/// Texte der Belegung mit fester Uhr und festem Kalender (Tests ohne Wanduhr).
struct OccupancyTexts {
    let now: Date
    let calendar: Calendar

    /// „heute 10:41“, „gestern 10:41“, sonst „06.11. 10:41“.
    func moment(_ date: Date) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "de_DE"),
                                                   calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "heute \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "gestern \(time)"
        }
        return "\(day(date)) \(time)"
    }

    /// „06.11.“
    func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d.%02d.", parts.day ?? 0, parts.month ?? 0)
    }

    func snapshots(_ summary: LocalSnapshotSummary?) -> String {
        guard let summary else { return "unbekannt" }
        guard summary.count > 0 else { return "keine" }
        return ["\(summary.count)", summary.oldest.map { "ältester \(day($0))" }].compactMap(\.self).joined(separator: ", ")
    }

    static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural)"
    }

    static func places(_ count: Int, protected: Bool = false) -> String {
        Self.count(count, protected ? "geschützten Ort" : "Ort", protected ? "geschützte Orte" : "Orte")
    }

    /// Größe; „≥“, wenn darunter etwas nicht erfasst ist.
    static func size(_ folder: OccupancyFolder) -> String {
        (folder.isComplete ? "" : "≥ ") + AppTexts.formattedSize(folder.allocatedBytes)
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0 %" }
        return fraction < 0.01 ? "< 1 %" : "\(Int((fraction * 100).rounded())) %"
    }

    /// „182.340 Dateien · 96,4 GB gelesen“; lang mit Ordnern und Satzende.
    static func progress(_ progress: OccupancyProgress?, long: Bool) -> String {
        guard let progress, progress.files > 0 || progress.folders > 0 else { return long ? "Der Scan beginnt." : "Scan beginnt …" }
        let files = count(progress.files, "Datei", "Dateien"), bytes = AppTexts.formattedSize(progress.allocatedBytes)
        return long ? "\(files) in \(count(progress.folders, "Ordner", "Ordnern")), \(bytes) gelesen."
            : "\(files) · \(bytes) gelesen"
    }

    /// „58 s“, „3 min 12 s“.
    static func duration(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 60 ? "\(max(seconds, 1)) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
