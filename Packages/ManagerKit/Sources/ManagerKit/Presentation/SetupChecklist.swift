/// Schritte der Einrichtung (Spec §6, Onboarding) in der Reihenfolge der Checkliste.
public enum SetupStep: String, Hashable, Sendable, CaseIterable, Identifiable {
    case fullDiskAccess, helper, notifications, launchAtLogin

    public var id: Self { self }

    /// Ohne diese Schritte bleiben Teile des Systems ungeprüft; die übrigen sind empfohlen.
    public var isRequired: Bool {
        switch self {
        case .fullDiskAccess, .helper: true
        case .notifications, .launchAtLogin: false
        }
    }

    public var title: String {
        switch self {
        case .fullDiskAccess: "Festplattenvollzugriff"
        case .helper: "Helper"
        case .notifications: "Benachrichtigungen"
        case .launchAtLogin: "Beim Anmelden starten"
        }
    }

    /// Wozu der Schritt dient.
    public var explanation: String {
        switch self {
        case .fullDiskAccess:
            "Nötig, um die systemweiten Berechtigungen zu lesen. Nach dem Erteilen erkennt Grantry ihn von selbst."
        case .helper:
            "Liest die Hintergrundobjekte des Systems und führt Aktionen mit Administratorrechten aus. Er nimmt nur Verbindungen von Administratoren an; die Genehmigung erfordert ein Administratorkonto."
        case .notifications:
            "Meldet neue, geänderte und entfernte Einträge, auch wenn das Fenster geschlossen ist."
        case .launchAtLogin:
            "Startet Grantry beim Anmelden, damit keine Änderung unbemerkt bleibt."
        }
    }
}

/// Ermittelter Zustand der Einrichtung; `nil` heißt jeweils „wird noch geprüft“.
public struct SetupStatus: Equatable, Sendable {
    public var fullDiskAccess: Bool?
    public var helper: HelperState?
    public var notifications: NotificationAuthorization?
    public var launchAtLogin: LoginItemStatus?

    public init(
        fullDiskAccess: Bool? = nil,
        helper: HelperState? = nil,
        notifications: NotificationAuthorization? = nil,
        launchAtLogin: LoginItemStatus? = nil
    ) {
        self.fullDiskAccess = fullDiskAccess
        self.helper = helper
        self.notifications = notifications
        self.launchAtLogin = launchAtLogin
    }
}

/// Checkliste der Einrichtung für Onboarding, Einstellungen und das Banner der Übersicht: Zustand, Text und
/// angebotene Aktion je Schritt sowie die Frage, ob die Einrichtung vollständig ist.
public struct SetupChecklist: Hashable, Sendable {
    /// Fortschritt eines Schritts.
    public enum State: Hashable, Sendable {
        /// Wird noch geprüft.
        case checking
        /// Erledigt.
        case done
        /// Offen; der Benutzer kann ihn erledigen.
        case open
        /// Offen, lässt sich hier aber nicht erledigen (z. B. ohne Administratorrechte).
        case blocked
    }

    /// Aktion, die für einen Schritt angeboten wird.
    public enum Action: Hashable, Sendable {
        case openFullDiskAccessSettings
        case helper(HelperStatePresentation.Action)
        case requestNotifications
        case openNotificationSettings
        case openLoginItemSettings

        /// Deutsche Schaltflächenbeschriftung.
        public var title: String {
            switch self {
            case .openFullDiskAccessSettings, .openNotificationSettings: "Einstellungen öffnen"
            case .helper(let action): action.title
            case .requestNotifications: "Erlauben …"
            case .openLoginItemSettings: "Anmeldeobjekte öffnen"
            }
        }
    }

    public struct Item: Hashable, Sendable, Identifiable {
        public let step: SetupStep
        public let state: State
        /// Zustand als Text, z. B. „Erteilt“.
        public let text: String
        /// `nil`, solange der Schritt geprüft wird.
        public let tone: PresentationTone?
        public let action: Action?

        public var id: SetupStep { step }
    }

    public let items: [Item]

    public init(_ status: SetupStatus) {
        items = SetupStep.allCases.map { Self.item(for: $0, status: status) }
    }

    public func item(for step: SetupStep) -> Item? {
        items.first { $0.step == step }
    }

    /// Erforderliche Schritte, die nachweislich fehlen; ungeprüfte zählen nicht.
    public var missingRequired: [Item] {
        items.filter { $0.step.isRequired && ($0.state == .open || $0.state == .blocked) }
    }

    /// `true`, wenn alle erforderlichen Schritte erledigt sind.
    public var isComplete: Bool {
        items.allSatisfy { !$0.step.isRequired || $0.state == .done }
    }

    /// Erster offener Schritt, den der Benutzer erledigen kann.
    public var nextStep: SetupStep? {
        items.first { $0.state == .open }?.step
    }

    /// Ob das Onboarding beim Start von selbst erscheint: beim ersten Start und immer dann, wenn ein erforderlicher
    /// Schritt fehlt, den der Benutzer erledigen kann. Nicht behebbare Lücken meldet nur das Banner.
    public func shouldPresentAutomatically(hasCompletedOnboarding: Bool) -> Bool {
        !hasCompletedOnboarding || missingRequired.contains { $0.state == .open }
    }

    /// Ob der Zustand nach dem Scan `snapshot` neu zu prüfen ist: wenn ein erforderlicher Schritt nachweislich fehlt
    /// (ist er inzwischen erledigt?) oder eine Quelle ausfiel, die von einem erforderlichen Schritt abhängt
    /// (`SourceID.requiredSetupStep`) – etwa die System-TCC-Datenbank vom Festplattenvollzugriff, BTM vom Helper. Beides
    /// kann verloren gehen, ohne dass die Einrichtung offen ist, etwa nach dem Austausch des App-Bundles.
    public func shouldRecheck(after snapshot: Snapshot) -> Bool {
        !missingRequired.isEmpty || snapshot.failedSources.contains { $0.requiredSetupStep != nil }
    }

    /// Text des Banners in der Übersicht; `nil`, wenn nichts Erforderliches fehlt.
    public var bannerText: String? {
        let missing = missingRequired
        guard !missing.isEmpty else { return nil }
        let parts = missing.map { item in
            switch item.step {
            case .fullDiskAccess: "Festplattenvollzugriff fehlt."
            default: "\(item.step.title): \(item.text)."
            }
        }
        return (parts + ["Ohne sie bleiben Teile des Systems ungeprüft."]).joined(separator: " ")
    }

    private static func item(for step: SetupStep, status: SetupStatus) -> Item {
        switch step {
        case .fullDiskAccess:
            switch status.fullDiskAccess {
            case true?: Item(step: step, state: .done, text: "Erteilt", tone: .positive, action: nil)
            case false?:
                Item(step: step, state: .open, text: "Nicht erteilt", tone: .critical, action: .openFullDiskAccessSettings)
            case nil: checking(step)
            }
        case .helper:
            status.helper.map { helperItem($0) } ?? checking(step)
        case .notifications:
            switch status.notifications {
            case .authorized?: Item(step: step, state: .done, text: "Erlaubt", tone: .positive, action: nil)
            case .notDetermined?:
                Item(step: step, state: .open, text: "Noch nicht erlaubt", tone: .warning, action: .requestNotifications)
            case .denied?:
                Item(step: step, state: .open, text: "Abgelehnt", tone: .warning, action: .openNotificationSettings)
            case nil: checking(step)
            }
        case .launchAtLogin:
            switch status.launchAtLogin {
            case .enabled?: Item(step: step, state: .done, text: "Aktiv", tone: .positive, action: nil)
            case .disabled?: Item(step: step, state: .open, text: "Aus", tone: .neutral, action: nil)
            case .requiresApproval?:
                Item(
                    step: step, state: .open, text: "Muss unter „Anmeldeobjekte & Erweiterungen“ erlaubt werden",
                    tone: .warning, action: .openLoginItemSettings
                )
            case nil: checking(step)
            }
        }
    }

    private static func helperItem(_ state: HelperState) -> Item {
        let presentation = HelperStatePresentation(state)
        let progress: State = switch state {
        case .ready: .done
        case .missingFromBundle, .requiresAdministrator: .blocked
        case .notInstalled, .awaitingApproval, .outdated, .unreachable: .open
        }
        return Item(
            step: .helper, state: progress, text: presentation.text, tone: presentation.tone,
            action: presentation.action.map(Action.helper)
        )
    }

    private static func checking(_ step: SetupStep) -> Item {
        Item(step: step, state: .checking, text: "Wird geprüft …", tone: nil, action: nil)
    }
}
