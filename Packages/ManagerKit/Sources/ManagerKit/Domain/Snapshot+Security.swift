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
