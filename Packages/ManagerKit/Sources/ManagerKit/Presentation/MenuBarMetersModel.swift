import Foundation
import Observation

/// Gespeicherte Einstellungen der Menüleisten-Elemente (TM17, Spec 2026-11-09 § 4): eingeschaltete Elemente,
/// Darstellung je Element, Kurzbezeichnung und die Tafel der Übersicht (Baukasten, Spec 2026-11-09-uebersicht-baukasten
/// § 6). Standard: alles aus, Kurzbezeichnung an, Tafel nicht angepasst.
public struct MenuBarMeterSettings: Codable, Equatable, Sendable {
    public var shown: Set<MenuBarMeterKind> = []
    public var styles: [MenuBarMeterKind: MenuBarMeterStyle] = [:]
    public var showsTags = true
    /// Ausgeblendete Karten aus #495: Grundlage der Übernahme, solange `overviewLayout` fehlt; bleibt für ältere
    /// Versionen unverändert gespeichert.
    public var hiddenCards: Set<MenuBarOverviewCard> = []
    /// Von Christian zusammengestellte Tafel; `nil`, solange er sie nicht geändert hat.
    public var overviewLayout: OverviewBoardLayout? {
        didSet { unreadableOverviewLayout = nil }
    }
    /// Gespeicherte Tafel, die diese Version nicht lesen kann (neuere Version): bleibt unverändert erhalten, bis
    /// Christian die Tafel ändert.
    private(set) var unreadableOverviewLayout: StoredJSON?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case shown, styles, showsTags, hiddenCards, overviewLayout
    }

    /// Ohne `hiddenCards` (gespeichert vor #495) alle Karten sichtbar, ohne `overviewLayout` (vor dem Baukasten) nicht
    /// angepasst. Eine nicht lesbare Tafel lässt die übrigen Einstellungen gelten.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shown = try container.decode(Set<MenuBarMeterKind>.self, forKey: .shown)
        styles = try container.decode([MenuBarMeterKind: MenuBarMeterStyle].self, forKey: .styles)
        showsTags = try container.decode(Bool.self, forKey: .showsTags)
        hiddenCards = try container.decodeIfPresent(Set<MenuBarOverviewCard>.self, forKey: .hiddenCards) ?? []
        do {
            overviewLayout = try container.decodeIfPresent(OverviewBoardLayout.self, forKey: .overviewLayout)
        } catch {
            unreadableOverviewLayout = try? container.decode(StoredJSON.self, forKey: .overviewLayout)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shown, forKey: .shown)
        try container.encode(styles, forKey: .styles)
        try container.encode(showsTags, forKey: .showsTags)
        try container.encode(hiddenCards, forKey: .hiddenCards)
        if let overviewLayout {
            try container.encode(overviewLayout, forKey: .overviewLayout)
        } else {
            try container.encodeIfPresent(unreadableOverviewLayout, forKey: .overviewLayout)
        }
    }

    /// Tafel der Übersicht auf einem Mac mit den Quellen `configured`: die gespeicherte, sonst die Übernahme der
    /// ausgeblendeten Karten; ist die gespeicherte nicht lesbar, der Standard. Ohne Kacheln, deren Quelle fehlt.
    public func overviewLayout(configured: Set<TaskManagerSource>) -> OverviewBoardLayout {
        if let overviewLayout { return overviewLayout.available(configured: configured) }
        if unreadableOverviewLayout != nil { return .standard(configured: configured) }
        return OverviewBoardLayout(migratingHiddenCards: hiddenCards, configured: configured)
    }

    /// Gewählte Darstellung, sofern das Element sie anbietet; sonst seine Standard-Darstellung.
    public func style(for kind: MenuBarMeterKind) -> MenuBarMeterStyle {
        styles[kind].flatMap { kind.styles.contains($0) ? $0 : nil } ?? kind.defaultStyle
    }
}

/// Elemente der Menüleiste samt Messbetrieb (TM17): Ist mindestens eines an, misst der Task-Manager für den Abnehmer
/// `.menuBar` – nur die Quellen der eingeschalteten Elemente (`MenuBarMeterKind.sources`). Gemessen wird erst nach
/// `activate()` (App-Start), damit Previews und Tests nichts starten. Ersetzt die Einstellung „Auslastung in der
/// Menüleiste anzeigen“ aus TM6 und übernimmt sie beim ersten Start.
@MainActor
@Observable
public final class MenuBarMetersModel {
    public static let storageKey = "menuBar.meters"
    /// Einstellung der Anzeige „Auslastung“ bis TM17.
    public static let legacyStorageKey = "taskManager.menuBar.isShown"

    public private(set) var settings: MenuBarMeterSettings
    /// Tafel der Übersicht (`MenuBarMeterSettings.overviewLayout(configured:)`).
    public private(set) var overviewLayout: OverviewBoardLayout
    /// Lage der Kacheln, nur bei geänderter Tafel neu gerechnet – nie je Takt (Spec 2026-11-09-uebersicht-baukasten § 7).
    public private(set) var overviewPlacements: [OverviewTilePlacement]
    @ObservationIgnored private let taskManager: TaskManagerModel
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let configured: Set<TaskManagerSource>
    @ObservationIgnored private var isActive = false
    /// Offene Ansichten der Tafel (Popover, Editor in den Einstellungen), die den Abnehmer `menuBarPopover` teilen.
    @ObservationIgnored private var overviewViewers = 0

    public init(taskManager: TaskManagerModel, settings store: any SettingsStore = UserDefaults.standard,
                configured: Set<TaskManagerSource>? = nil) {
        self.taskManager = taskManager
        self.store = store
        let configured = configured ?? taskManager.configuredSources
        let settings = Self.restore(from: store)
        self.configured = configured
        self.settings = settings
        let layout = settings.overviewLayout(configured: configured)
        overviewLayout = layout
        overviewPlacements = layout.placements()
    }

    private static func restore(from store: any SettingsStore) -> MenuBarMeterSettings {
        if let data = store.object(forKey: storageKey) as? Data,
           let settings = try? JSONDecoder().decode(MenuBarMeterSettings.self, from: data) {
            return settings
        }
        var settings = MenuBarMeterSettings()
        if store.bool(forKey: legacyStorageKey) { settings.shown = [.overview] }
        return settings
    }

    public func isShown(_ kind: MenuBarMeterKind) -> Bool {
        settings.shown.contains(kind) && isAvailable(kind)
    }

    /// Schaltet ein Element ein oder aus; entfernt der Nutzer das Statusobjekt per ⌘-Ziehen, schaltet das das Element aus
    /// (`MenuBarMeterStatusItems` in der App). Elemente ohne eingerichtete Quelle bleiben aus.
    public func setShown(_ isShown: Bool, for kind: MenuBarMeterKind) {
        guard isShown != self.isShown(kind), !isShown || isAvailable(kind) else { return }
        update { $0.shown.formSymmetricDifference([kind]) }
        if isActive { apply() }
    }

    /// Eingerichtete Quellen dieses Macs: Katalog und Standard der Tafel ohne nicht verfügbare Kacheln.
    public var configuredSources: Set<TaskManagerSource> { configured }

    /// Ein Element ohne eingerichtete Quelle (Akku am Mac ohne Akku) lässt sich nicht einschalten.
    public func isAvailable(_ kind: MenuBarMeterKind) -> Bool {
        kind.sources.isSubset(of: configured)
    }

    public func style(for kind: MenuBarMeterKind) -> MenuBarMeterStyle { settings.style(for: kind) }

    public func setStyle(_ style: MenuBarMeterStyle, for kind: MenuBarMeterKind) {
        guard kind.styles.contains(style) else { return }
        update { $0.styles[kind] = style }
    }

    public var showsTags: Bool {
        get { settings.showsTags }
        set { update { $0.showsTags = newValue } }
    }

    /// Speichert die Tafel, wie Christian sie zusammengestellt hat; ab dann gilt sie statt der übernommenen Karten.
    public func setOverviewLayout(_ layout: OverviewBoardLayout) {
        guard layout != overviewLayout else { return }
        update { $0.overviewLayout = layout }
        overviewLayout = settings.overviewLayout(configured: configured)
        overviewPlacements = overviewLayout.placements()
        if overviewViewers > 0 { measureOverview() }
    }

    /// Eine Ansicht der Tafel öffnet (Popover der Übersicht, Editor in den Einstellungen): misst zusätzlich die Quellen
    /// ihrer Kacheln (Abnehmer `menuBarPopover`), nur solange eine offen ist. Ohne Prozess-Kachel keine Prozessquelle.
    public func beginOverviewMeasurement() {
        overviewViewers += 1
        measureOverview()
    }

    public func endOverviewMeasurement() {
        guard overviewViewers > 0 else { return }
        overviewViewers -= 1
        if overviewViewers == 0 { taskManager.stop(for: .menuBarPopover) }
    }

    private func measureOverview() {
        taskManager.start(for: .menuBarPopover, sources: overviewLayout.requirements.sources)
    }

    /// Ab dem App-Start: misst, solange ein Element an ist.
    public func activate() {
        isActive = true
        apply()
    }

    private func update(_ change: (inout MenuBarMeterSettings) -> Void) {
        var settings = settings
        change(&settings)
        guard settings != self.settings else { return }
        self.settings = settings
        store.set(try? JSONEncoder().encode(settings), forKey: Self.storageKey)
    }

    private func apply() {
        let shown = MenuBarMeterKind.allCases.filter(isShown)
        if shown.isEmpty {
            taskManager.stop(for: .menuBar)
        } else {
            taskManager.start(for: .menuBar, sources: shown.reduce(into: []) { $0.formUnion($1.sources) })
        }
    }
}

/// Beliebiger JSON-Wert, unverändert durchgereicht: hält eine Tafel einer neueren Version, die diese nicht lesen kann.
enum StoredJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([StoredJSON])
    case object([String: StoredJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([StoredJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: StoredJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
