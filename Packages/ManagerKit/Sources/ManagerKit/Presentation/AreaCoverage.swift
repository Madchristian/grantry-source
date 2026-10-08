import Foundation

/// Inventarbereich mit eigener Scan-Abdeckung (#142) – je Bereich die Quellen, aus denen seine Liste stammt.
public enum InventoryArea: String, Hashable, Sendable, CaseIterable, Identifiable {
    case apps, permissions, autostart, agents, network, security

    public var id: Self { self }

    /// Deutscher Name wie in der Sidebar.
    public var title: String {
        switch self {
        case .apps: "Apps"
        case .permissions: "Berechtigungen"
        case .autostart: "Autostart"
        case .agents: "Agenten"
        case .network: "Netzwerk"
        case .security: "Sicherheit"
        }
    }

    /// Quellen, deren Einträge der Bereich zeigen kann; welche davon erwartet werden, bestimmen die aktiven Quellen
    /// (`expectedSources(activeSources:)`).
    public var sources: [SourceID] {
        switch self {
        case .apps: [.apps]
        case .permissions: [.tccUser, .tccSystem]
        case .autostart: [.launchd, .btm]
        case .agents: [.agents]
        case .network: [.networkListeners]
        case .security: [.securityPosture]
        }
    }

    /// Quellen, deren Abdeckung der Bereich verlangt: die aktiven unter `sources`; `nil`: alle.
    public func expectedSources(activeSources: Set<SourceID>?) -> [SourceID] {
        activeSources.map { active in sources.filter(active.contains) } ?? sources
    }
}

extension SourceID {
    /// Deutscher Name der Quelle für Hinweise.
    public var displayName: String {
        switch self {
        case .tccUser: "Berechtigungen (Benutzer)"
        case .tccSystem: "Berechtigungen (System)"
        case .launchd: "launchd"
        case .btm: "Hintergrundobjekte"
        case .securityPosture: "Sicherheit"
        case .apps: "Apps"
        case .networkListeners: "Netzwerkdienste"
        case .agents: "Agenten-Konfigurationen"
        default: rawValue
        }
    }

    /// Ruhiger Hinweis, wenn die Quelle bewusst nicht gescannt wird (`AreaCoverage.notes`) – keine Lücke.
    public var exclusionNote: String {
        switch self {
        case .tccUser: "Benutzerbezogene Berechtigungen werden nicht ausgewertet."
        default: "\(displayName) wird nicht ausgewertet."
        }
    }

    /// Was eine Zwischenmessung der Quelle abdeckt (`Snapshot.lastInterimDeliveryBySource`).
    public var interimScope: String {
        switch self {
        case .networkListeners: "eigene Dienste"
        default: "Teil von \(displayName)"
        }
    }

    /// Einrichtungsschritt, ohne den die Quelle ausfällt oder nur eingeschränkt liefert: die System-TCC-Datenbank
    /// braucht Festplattenvollzugriff, Hintergrundobjekte und die Dienste anderer Benutzer den Helper.
    public var requiredSetupStep: SetupStep? {
        switch self {
        case .tccSystem: .fullDiskAccess
        case .btm, .networkListeners: .helper
        default: nil
        }
    }
}

/// Nächster Schritt, der eine Abdeckungslücke schließen kann (`AreaCoverage.nextStep(missingSetupSteps:)`).
public enum CoverageNextStep: Hashable, Sendable {
    /// Ein erforderlicher Einrichtungsschritt fehlt nachweislich.
    case setUp(SetupStep)
    /// Erneut scannen – nur, wenn das die Lücke beheben kann (Quellenfehler, noch nicht gelieferte Quelle, behebbare
    /// Einschränkung wie eine Zeitüberschreitung).
    case rescan

    /// Deutsche Schaltflächenbeschriftung.
    public var title: String {
        switch self {
        case .setUp(.fullDiskAccess): "Festplattenvollzugriff erteilen …"
        case .setUp: "Einrichtung öffnen …"
        case .rescan: "Erneut prüfen"
        }
    }

    /// VoiceOver-Hinweis, was die Schaltfläche bewirkt.
    public var hint: String {
        switch self {
        case .setUp(.fullDiskAccess): "Öffnet die Systemeinstellungen für den Festplattenvollzugriff."
        case .setUp: "Öffnet die Einrichtung von Grantry."
        case .rescan: "Startet einen neuen Scan."
        }
    }
}

/// Wie aktuell und vollständig ein Inventarbereich gelesen wurde (#142) – gemeinsame Aufbereitung für den Hinweis über
/// jeder Liste, die leeren Zustände, die Übersicht und die Menüleiste. Grundlage sind die Quellenfehler
/// (`Snapshot.sourceErrors`, Einträge fortgeschrieben), die Einschränkungen (`Snapshot.sourceLimitations`), die
/// Lieferzeitpunkte (`Snapshot.lastDeliveryBySource`) und fortgeschriebene Autostart-Einträge (`AutostartItem.lastVerifiedAt`).
///
/// „Aktuell“ verlangt positive Evidenz: Jede Quelle des Bereichs muss eine Lieferung nachweisen (`baselineSources` oder
/// `lastDeliveryBySource`). Eine Quelle ohne Fehler und ohne Nachweis – etwa in einem älteren Snapshot vor dem ersten
/// Scan mit ihr – ist eine Lücke, nie eine Entwarnung. Erwartet werden nur aktive Quellen (`activeSources`): Eine bewusst
/// nicht gescannte Quelle (v1: Benutzer-TCC) ist keine Lücke, sondern ein ruhiger Hinweis (`notes`).
public struct AreaCoverage: Hashable, Sendable, Identifiable {
    /// Zustand, schlechtester zuletzt.
    public enum State: Int, Hashable, Sendable, Comparable {
        /// Alle Quellen haben nachweislich und vollständig geliefert.
        case current
        /// Geliefert, aber nicht alles war lesbar – oder eine Quelle hat noch nie geliefert, während die übrigen es taten.
        case partial
        /// Eine Quelle ist ausgefallen; ihre Einträge stammen aus einem früheren Scan.
        case lastKnown
        /// Keine Quelle des Bereichs hat nachweislich geliefert: Es gibt keinen bekannten Stand.
        case unread

        public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Eine Lücke einer Quelle des Bereichs.
    public struct Gap: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// Quelle ausgefallen (`SourceError`); `lastDelivery` ist der Stand ihrer fortgeschriebenen Einträge, `nil`,
            /// wenn er unbekannt ist. `hasEverDelivered == false`: Es gibt keine Einträge von ihr.
            case failed(lastDelivery: Date?, hasEverDelivered: Bool)
            /// Quelle hat eingeschränkt geliefert (`SourceLimitation`); `isRetryable`: Ein Scan kann es beheben.
            case limited(isRetryable: Bool)
            /// Weder Fehler noch Lieferung: Die Quelle ist (in diesem Stand) noch nie gelesen worden; `message` ist leer.
            case notDelivered
            /// Nur Zwischenmessungen (`Snapshot.lastInterimDeliveryBySource`), noch keine vollständige Lieferung – und
            /// keine Einschränkung, die das schon erklärt; `message` ist leer.
            case interimOnly(at: Date)
        }

        public let source: SourceID
        public let kind: Kind
        public let message: String

        /// Ein erneuter Scan kann die Lücke schließen: ausgefallene oder noch nicht gelieferte Quellen und behebbare
        /// Einschränkungen.
        public var isRetryable: Bool {
            switch kind {
            case .failed, .notDelivered, .interimOnly: true
            case .limited(let isRetryable): isRetryable
            }
        }
    }

    public let area: InventoryArea
    public let state: State
    /// Zeitpunkt, für den die Liste gilt: bei `.current`/`.partial` die älteste Lieferung einer Quelle des Bereichs (ohne
    /// bekannte Lieferung der Scan selbst), bei `.lastKnown` die älteste Lieferung einer ausgefallenen Quelle (`nil`:
    /// unbekannt), bei `.unread` `nil`.
    public let checkedAt: Date?
    public let gaps: [Gap]
    /// Autostart-Einträge, die nur fortgeschrieben sind (`AutostartItem.isCurrent == false`).
    public let outdatedRecordCount: Int
    /// Ruhige, dauerhafte Hinweise zu bewusst nicht gescannten Quellen (`SourceID.exclusionNote`); ohne Einfluss auf den
    /// Zustand.
    public let exclusionNotes: [String]
    /// Zwischenmessungen nach der letzten vollständigen Lieferung je Quelle (`Snapshot.lastInterimDeliveryBySource`):
    /// Sie ersetzen deren Zeitpunkt nicht, `notes(now:)` nennt sie (#142).
    public let interimMeasurements: [SourceID: Date]

    public var id: InventoryArea { area }

    /// - Parameter activeSources: Quellen, die ein Vollscan fragt (`MonitoringState.activeSources`); `nil`: alle.
    ///   Fehler und Einschränkungen anderer Quellen zählen nicht.
    public init(area: InventoryArea, snapshot: Snapshot, activeSources: Set<SourceID>? = nil) {
        let expected = area.expectedSources(activeSources: activeSources)
        let sources = Set(expected)
        let hasDelivered = { (source: SourceID) in
            snapshot.baselineSources.contains(source) || snapshot.lastDeliveryBySource[source] != nil
        }
        let failed = snapshot.sourceErrors.filter { sources.contains($0.source) }
        let failedSources = Set(failed.map(\.source))
        let unfailed = expected.filter { !failedSources.contains($0) }
        let delivered = unfailed.filter(hasDelivered)
        let gaps = failed.map { error in
            Gap(source: error.source,
                kind: .failed(lastDelivery: snapshot.lastDeliveryBySource[error.source],
                              hasEverDelivered: hasDelivered(error.source)),
                message: error.message)
        } + unfailed.filter { !hasDelivered($0) }.map {
            Gap(source: $0, kind: .notDelivered, message: "")
        } + delivered.compactMap { source in
            // Nur Zwischenmessungen ohne erklärende Einschränkung: keine vollständige Prüfung, nie „aktuell“.
            guard snapshot.lastDeliveryBySource[source] == nil, let interim = snapshot.lastInterimDeliveryBySource[source],
                  !snapshot.sourceLimitations.contains(where: { $0.source == source }) else { return nil }
            return Gap(source: source, kind: .interimOnly(at: interim), message: "")
        } + snapshot.sourceLimitations.filter { sources.contains($0.source) }.map {
            Gap(source: $0.source, kind: .limited(isRetryable: $0.isRetryable), message: $0.message)
        }
        let outdated = area == .autostart ? snapshot.autostartItems.count { !$0.isCurrent } : 0
        let carried = failed.filter { hasDelivered($0.source) }

        self.area = area
        self.gaps = gaps
        outdatedRecordCount = outdated
        exclusionNotes = area.sources.filter { !sources.contains($0) }.map(\.exclusionNote)
        interimMeasurements = snapshot.lastInterimDeliveryBySource.filter { source, _ in
            delivered.contains(source) && snapshot.lastDeliveryBySource[source] != nil
        }
        if !carried.isEmpty {
            state = .lastKnown
            let dates = carried.map { snapshot.lastDeliveryBySource[$0.source] }
            checkedAt = dates.contains(nil) ? nil : dates.compactMap(\.self).min()
        } else if delivered.isEmpty {
            state = .unread
            checkedAt = nil
        } else {
            state = gaps.isEmpty && outdated == 0 ? .current : .partial
            // Stand der vollständigen Lieferung; eine Zwischenmessung zählt nur ohne sie (dann ist der Bereich nie aktuell).
            checkedAt = delivered.compactMap { snapshot.lastDeliveryBySource[$0] ?? snapshot.lastInterimDeliveryBySource[$0] }
                .min() ?? snapshot.takenAt
        }
    }

    /// `true`, wenn alles gelesen wurde – nur dann ist eine leere Liste eine Entwarnung.
    public var isComplete: Bool { state == .current }

    public var tone: PresentationTone {
        switch state {
        case .current: .positive
        case .partial, .lastKnown: .warning
        case .unread: .critical
        }
    }

    /// SF Symbol je Zustand – ergänzt die Farbe, damit der Zustand auch ohne sie erkennbar ist.
    public var systemImage: String {
        switch state {
        case .current: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .lastKnown: "clock.badge.exclamationmark"
        case .unread: "xmark.circle.fill"
        }
    }

    /// „Aktuell“, „Teilweise geprüft“, „Letzter bekannter Stand“, „Nicht geprüft“.
    public var headline: String {
        switch state {
        case .current: "Aktuell"
        case .partial: "Teilweise geprüft"
        case .lastKnown: "Letzter bekannter Stand"
        case .unread: "Nicht geprüft"
        }
    }

    /// „Geprüft heute, 10:50“, „Stand von gestern, 10:50“, „Stand unbekannt“, „Noch nie gelesen“.
    public func timeText(now: Date, calendar: Calendar = .current) -> String {
        switch state {
        case .current, .partial:
            checkedAt.map { "Geprüft \(CoverageTexts.timestamp($0, now: now, calendar: calendar))" } ?? "Geprüft"
        case .lastKnown:
            checkedAt.map { "Stand von \(CoverageTexts.timestamp($0, now: now, calendar: calendar))" } ?? "Stand unbekannt"
        case .unread:
            "Noch nie gelesen"
        }
    }

    /// Zustandszeile: „Teilweise geprüft · Geprüft heute, 10:50“.
    public func statusLine(now: Date, calendar: Calendar = .current) -> String {
        "\(headline) · \(timeText(now: now, calendar: calendar))"
    }

    /// Kompakte Zeile für Übersicht und Menüleiste: „Autostart: Teilweise geprüft · Geprüft heute, 10:50“.
    public func summaryLine(now: Date, calendar: Calendar = .current) -> String {
        "\(area.title): \(statusLine(now: now, calendar: calendar))"
    }

    /// Umfang und Grund der Einschränkung, eine Zeile je Lücke (Pfade unter `home` mit `~`); leer bei `.current`.
    /// Die Quelle steht nur dabei, wenn der Bereich mehrere erwartet.
    public func reasons(now: Date, calendar: Calendar = .current, home: String = NSHomeDirectory()) -> [String] {
        let namesSource = area.sources.count - exclusionNotes.count > 1
        let gapLines = gaps.map { gap in
            let prefix = namesSource ? "\(gap.source.displayName): " : ""
            let message = PathDisplay.abbreviatingHomePaths(in: gap.message, home: home)
            switch gap.kind {
            case .limited:
                return prefix + message
            case .notDelivered:
                return prefix.isEmpty ? "Noch nicht gelesen – kein bekannter Stand" : "\(prefix)noch nicht gelesen – kein bekannter Stand"
            case .interimOnly(let date):
                return "\(prefix)Bisher nur \(gap.source.interimScope) gemessen (\(CoverageTexts.timestamp(date, now: now, calendar: calendar)))"
                    + " – noch keine vollständige Prüfung"
            case .failed(let lastDelivery, let hasEverDelivered):
                let age = !hasEverDelivered ? "noch kein bekannter Stand"
                    : lastDelivery.map { "angezeigt wird der Stand von \(CoverageTexts.timestamp($0, now: now, calendar: calendar))" }
                    ?? "angezeigt wird der letzte bekannte Stand"
                return "\(prefix)nicht gelesen (\(message)) – \(age)"
            }
        }
        return gapLines + (outdatedRecordCount > 0 ? [Self.outdatedText(outdatedRecordCount)] : [])
    }

    /// Ruhige Hinweise ohne Einfluss auf den Zustand: bewusst nicht gescannte Quellen und Zwischenmessungen seit der
    /// vollständigen Prüfung („Eigene Dienste zuletzt gemessen: heute, 10:59“).
    public func notes(now: Date, calendar: Calendar = .current) -> [String] {
        exclusionNotes + interimMeasurements.sorted { $0.key.rawValue < $1.key.rawValue }.map { source, date in
            let scope = source.interimScope
            return "\(scope.prefix(1).uppercased() + scope.dropFirst()) zuletzt gemessen: "
                + CoverageTexts.timestamp(date, now: now, calendar: calendar)
        }
    }

    /// Ergänzung für eine leere Liste oder „Nichts Auffälliges“; `nil`, wenn alles gelesen wurde.
    public var emptyListCaveat: String? {
        isComplete ? nil : "Nicht vollständig geprüft – eine leere Liste ist hier keine Entwarnung."
    }

    /// VoiceOver-Fassung des Zustands: „Abdeckung Autostart: Teilweise geprüft. Geprüft heute, 10:50.“
    public func accessibilityLabel(now: Date, calendar: Calendar = .current) -> String {
        "Abdeckung \(area.title): \(headline). \(timeText(now: now, calendar: calendar))."
    }

    /// Passender nächster Schritt; `nil`, wenn alles gelesen wurde oder nichts in Grantry die Lücke schließt (etwa eine
    /// kaputte Plist, ein Netzlaufwerk). Ein fehlender Einrichtungsschritt, von dem eine betroffene Quelle abhängt
    /// (`SourceID.requiredSetupStep`), geht vor; „Erneut prüfen“ nur, wenn ein Scan sie beheben kann (`Gap.isRetryable`).
    /// - Parameter missingSetupSteps: nachweislich fehlende erforderliche Schritte (`SetupChecklist.missingRequired`).
    public func nextStep(missingSetupSteps: Set<SetupStep>) -> CoverageNextStep? {
        guard !isComplete else { return nil }
        if let step = gaps.lazy.compactMap(\.source.requiredSetupStep).first(where: missingSetupSteps.contains) {
            return .setUp(step)
        }
        return gaps.contains(where: \.isRetryable) ? .rescan : nil
    }

    private static func outdatedText(_ count: Int) -> String {
        count == 1
            ? "1 Eintrag zeigt einen alten Stand; Aktionen dafür sind bis zum erneuten Lesen gesperrt."
            : "\(count) Einträge zeigen einen alten Stand; Aktionen dafür sind bis zum erneuten Lesen gesperrt."
    }
}

/// Abdeckung aller Inventarbereiche eines Snapshots (`PresentationSnapshot.coverage`).
public struct CoverageOverview: Hashable, Sendable {
    /// In der Reihenfolge von `InventoryArea.allCases`; Bereiche ohne aktive Quelle fehlen.
    public let areas: [AreaCoverage]

    /// Nur Bereiche mit mindestens einer erwarteten Quelle.
    /// - Parameter activeSources: Quellen, die ein Vollscan fragt; `nil`: alle.
    public init(snapshot: Snapshot, activeSources: Set<SourceID>? = nil) {
        areas = InventoryArea.allCases
            .filter { !$0.expectedSources(activeSources: activeSources).isEmpty }
            .map { AreaCoverage(area: $0, snapshot: snapshot, activeSources: activeSources) }
    }

    public subscript(area: InventoryArea) -> AreaCoverage? {
        areas.first { $0.area == area }
    }

    /// Bereiche, die nicht vollständig gelesen wurden, schlechtester Zustand zuerst (sonst in Bereichsreihenfolge).
    public var incomplete: [AreaCoverage] {
        areas.enumerated().filter { !$0.element.isComplete }
            .sorted { $0.element.state != $1.element.state ? $0.element.state > $1.element.state : $0.offset < $1.offset }
            .map(\.element)
    }
}

extension CoverageTexts {
    /// „heute, 10:50“, „gestern, 10:50“, „3. Okt., 10:50“, in einem anderen Jahr „3. Okt. 2025, 10:50“ (deutsch).
    public static func timestamp(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: "de_DE")
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "heute, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "gestern, \(time)"
        }
        var day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return "\(date.formatted(day)), \(time)"
    }
}
