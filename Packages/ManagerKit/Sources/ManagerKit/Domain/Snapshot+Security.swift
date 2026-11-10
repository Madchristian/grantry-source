import Foundation

extension Snapshot {
    /// Schreibt den Sicherheitszustand aus `previous` fort und bewertet neu (Spec v2 §2/§4):
    /// - ausgefallene Prüfung (`unknown`): Fakten und letzte bekannte Ampel des Vorgängers,
    /// - ausstehende Updates: je `identifier` das frühere `firstSeenAt`, danach Ampel zu `now` neu bewertet.
    ///
    /// Idempotent: Erneutes Anwenden mit demselben Vorgänger ändert nichts.
    func carryingForwardSecurityState(from previous: Snapshot?, policy: SecurityPolicy, now: Date) -> Snapshot {
        guard !securityChecks.isEmpty else { return self }
        let previousByKind = Dictionary(
            (previous?.securityChecks ?? []).map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var result = self
        result.securityChecks = securityChecks.map {
            $0.carryingForward(from: previousByKind[$0.kind], policy: policy, now: now)
        }
        return result
    }

    /// Ersetzt die Prüfung „Freigabedienste“ durch eine frisch aus `networkListeners` abgeleitete (#409) – ohne eigenen
    /// Scan, auch in Teilscans, damit sie dem Stand der Lauscher folgt. Die Dienste von macOS lauschen als root: Ohne
    /// vollständiges Bild aller Benutzer (Quelle ausgefallen, nur eigene Dienste lesbar, noch nie vollständig geliefert)
    /// ist sie `unknown` mit Einschränkung, nie eine Entwarnung; Fakten und letzte Ampel kommen dann aus `previous`.
    ///
    /// Idempotent: Erneutes Anwenden mit demselben Vorgänger ändert nichts.
    func derivingSharingServicesCheck(from previous: Snapshot?, policy: SecurityPolicy, now: Date) -> Snapshot {
        let fresh = if let gap = listenerGapForSharingServices {
            SecurityCheck.failed(.sharingServices, detail: gap)
        } else {
            SecurityCheck(evaluating: .sharingServices(active: SharingService.active(in: networkListeners)),
                          policy: policy, now: now)
        }
        let check = fresh.carryingForward(
            from: previous?.securityChecks.first { $0.kind == .sharingServices }, policy: policy, now: now
        )
        let prefix = SecurityPostureSource.limitationPrefix(of: .sharingServices)
        var result = self
        result.securityChecks = (securityChecks.filter { $0.kind != .sharingServices } + [check]).sortedByKind()
        result.sourceLimitations = sourceLimitations.filter {
            !($0.source == .securityPosture && $0.message.hasPrefix(prefix))
        } + SecurityPostureSource.limitations(of: [check]).map {
            SourceLimitation(source: .securityPosture, message: $0, isRetryable: true)
        }
        return result
    }

    /// Warum die Lauscher nicht alle Dienste zeigen; `nil`, wenn sie vollständig sind. Nicht behebbare Hinweise der
    /// Quelle (geschützte Prozesse) zählen nicht – die Dienste von macOS hält launchd, und das liest der Helper.
    private var listenerGapForSharingServices: String? {
        if let error = sourceErrors.first(where: { $0.source == .networkListeners }) {
            return "Netzwerkdienste nicht lesbar – \(error.message)"
        }
        if let limitation = sourceLimitations.first(where: { $0.source == .networkListeners && $0.isRetryable }) {
            return limitation.message
        }
        return hasCompleteListenerBaseline ? nil : "Dienste des Systems noch nicht vollständig gelesen"
    }
}

extension SecurityCheck {
    /// Diese Prüfung mit den fortgeschriebenen Werten aus `previous` (siehe `Snapshot.carryingForwardSecurityState`).
    func carryingForward(from previous: SecurityCheck?, policy: SecurityPolicy, now: Date) -> SecurityCheck {
        var result = self
        guard state != .unknown else {
            result.facts = facts ?? previous?.facts
            result.lastKnownState = previous?.effectiveState
            return result
        }
        guard let facts else { return result }
        let carried = facts.carryingFirstSeenDates(from: previous?.facts)
        result.facts = carried
        result.state = policy.evaluate(carried, now: now)
        return result
    }
}

extension SecurityFacts {
    /// Ausstehende Updates behalten das frühere `firstSeenAt` ihres `identifier`.
    func carryingFirstSeenDates(from previous: SecurityFacts?) -> SecurityFacts {
        guard case .pendingUpdates(let updates, let lastCheck) = self,
              case .pendingUpdates(let previousUpdates, _)? = previous
        else { return self }
        let firstSeen = Dictionary(previousUpdates.map { ($0.identifier, $0.firstSeenAt) }, uniquingKeysWith: min)
        return .pendingUpdates(updates: updates.map { update in
            var update = update
            if let earlier = firstSeen[update.identifier] { update.firstSeenAt = min(update.firstSeenAt, earlier) }
            return update
        }, lastCheck: lastCheck)
    }
}
