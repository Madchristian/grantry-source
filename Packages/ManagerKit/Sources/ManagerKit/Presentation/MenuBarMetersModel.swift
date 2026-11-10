import Foundation
import Observation

/// Gespeicherte Einstellungen der Menüleisten-Elemente (TM17, Spec 2026-11-09 § 4): eingeschaltete Elemente,
/// Darstellung je Element, Kurzbezeichnung und ausgeblendete Karten der Übersicht (#495). Standard: alles aus,
/// Kurzbezeichnung an, alle Karten sichtbar.
public struct MenuBarMeterSettings: Codable, Equatable, Sendable {
    public var shown: Set<MenuBarMeterKind> = []
    public var styles: [MenuBarMeterKind: MenuBarMeterStyle] = [:]
    public var showsTags = true
    public var hiddenCards: Set<MenuBarOverviewCard> = []

    public init() {}

    /// Ohne `hiddenCards` (gespeichert vor #495) alle Karten sichtbar.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shown = try container.decode(Set<MenuBarMeterKind>.self, forKey: .shown)
        styles = try container.decode([MenuBarMeterKind: MenuBarMeterStyle].self, forKey: .styles)
        showsTags = try container.decode(Bool.self, forKey: .showsTags)
        hiddenCards = try container.decodeIfPresent(Set<MenuBarOverviewCard>.self, forKey: .hiddenCards) ?? []
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
    @ObservationIgnored private let taskManager: TaskManagerModel
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let configured: Set<TaskManagerSource>
    @ObservationIgnored private var isActive = false

    public init(taskManager: TaskManagerModel, settings store: any SettingsStore = UserDefaults.standard,
                configured: Set<TaskManagerSource>? = nil) {
        self.taskManager = taskManager
        self.store = store
        self.configured = configured ?? taskManager.configuredSources
        settings = Self.restore(from: store)
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

    public var hiddenCards: Set<MenuBarOverviewCard> { settings.hiddenCards }

    public func isCardShown(_ card: MenuBarOverviewCard) -> Bool { !settings.hiddenCards.contains(card) }

    /// Blendet eine Karte der Übersicht ein oder aus.
    public func setCardShown(_ isShown: Bool, for card: MenuBarOverviewCard) {
        update { settings in
            if isShown { settings.hiddenCards.remove(card) } else { settings.hiddenCards.insert(card) }
        }
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
