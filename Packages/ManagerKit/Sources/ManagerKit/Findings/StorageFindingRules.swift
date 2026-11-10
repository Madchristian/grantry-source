import Foundation

/// Datenträger-Befunde (TM-15.5, Spec 2026-11-08 §5.4) aus dem Volume-Inventar (`VolumeInventory`): Volume über
/// `volumeFull` belegt, SMART-Fehler (kritisch), ältester lokaler Snapshot älter als `staleSnapshots`. Zustände statt
/// Messreihen – das Inventar wird nach einem Scan gelesen (`VolumeFindingCheck`), nicht mit einem eigenen Takt.
extension FindingRules {
    /// Laufende Datenträger-Befunde zum Zeitpunkt `time` der Prüfung. Beginn ist die erste Prüfung, an der die
    /// Bedingung galt: Ein Befund aus `previous` (laufende Befunde der letzten Prüfung), der noch gilt, behält Beginn und
    /// ID. Ein unvollständiges Inventar widerlegt nichts – laufende Befunde, die es nicht erneut bestätigt, laufen
    /// weiter; ein vollständiges beendet sie (sie fehlen im Ergebnis).
    public static func storageFindings(in inventory: VolumeInventory, at time: Date,
                                       continuing previous: [SystemFinding] = [],
                                       thresholds: FindingThresholds = .standard) -> [SystemFinding] {
        let current = volumeFindings(inventory, at: time, thresholds: thresholds)
            + smartFindings(inventory, at: time, thresholds: thresholds)
            + snapshotFindings(inventory, at: time, thresholds: thresholds)
        let running = previous.filter { $0.isOngoing && $0.kind.isStorage }
        let continued = current.map { finding in
            guard let earlier = running.first(where: { $0.matches(finding) }) else { return finding }
            return SystemFinding(kind: finding.kind, tone: finding.tone, reason: finding.reason, start: earlier.start,
                                 end: nil, evidence: finding.evidence, subject: finding.subject)
        }
        let unconfirmed = inventory.isComplete ? [] : running.filter { earlier in !current.contains(where: earlier.matches) }
        return (continued + unconfirmed).sorted {
            ($0.start, $0.kind.rawValue, $0.id.uuidString) < ($1.start, $1.kind.rawValue, $1.id.uuidString)
        }
    }

    /// Was das Wachbuch von einer Prüfung zur nächsten erfährt: neue Befunde (Beginn, ohne Ende) und widerlegte, die mit
    /// dem Zeitpunkt `time` dieser Prüfung enden – genauer ist ihr Ende ohne eigenen Takt nicht bekannt. Fortgesetzte
    /// Befunde (gleiche ID) stehen schon im Wachbuch.
    public static func storageChanges(from previous: [SystemFinding], to current: [SystemFinding],
                                      at time: Date) -> [SystemFinding] {
        let previousIDs = Set(previous.map(\.id)), currentIDs = Set(current.map(\.id))
        let ended = previous.filter { !currentIDs.contains($0.id) }.map {
            SystemFinding(kind: $0.kind, tone: $0.tone, reason: $0.reason, start: $0.start, end: time,
                          evidence: $0.evidence, subject: $0.subject)
        }
        return current.filter { !previousIDs.contains($0.id) } + ended
    }

    /// Je eingehängtem Container mit Platz des Benutzers (System-, Daten- oder gewöhnliches Volume); Hilfscontainer wie
    /// Wiederherstellung oder iSCPreboot zählen nicht. Was macOS bei Bedarf freigibt, zählt als frei; ohne Messung des
    /// Dateisystems gilt der freie Platz laut `diskutil`.
    private static func volumeFindings(_ inventory: VolumeInventory, at time: Date,
                                       thresholds: FindingThresholds) -> [SystemFinding] {
        let rule = thresholds.volumeFull
        return inventory.devices.flatMap(\.containers).compactMap { container -> SystemFinding? in
            guard let volume = userVolume(of: container), let share = usedShare(of: container), share > rule.limit
            else { return nil }
            return storageFinding(.volumeFull, name: volume.name, at: time,
                                  evidence: .init(limit: rule.limit, peak: share, mean: share), thresholds: thresholds)
        }
    }

    private static func smartFindings(_ inventory: VolumeInventory, at time: Date,
                                      thresholds: FindingThresholds) -> [SystemFinding] {
        inventory.devices.filter { $0.smartStatus == .failing }.map { device in
            storageFinding(.smartFailure, name: device.name ?? device.id, at: time,
                           evidence: .init(limit: thresholds.smartFailure.limit, peak: 1, mean: 1),
                           thresholds: thresholds)
        }
    }

    /// Bezug ist das Startvolume (eingehängt unter „/“), sofern es im Inventar steht.
    private static func snapshotFindings(_ inventory: VolumeInventory, at time: Date,
                                         thresholds: FindingThresholds) -> [SystemFinding] {
        let rule = thresholds.staleSnapshots
        guard let oldest = inventory.localSnapshots?.oldest else { return [] }
        let age = time.timeIntervalSince(oldest)
        guard age > rule.limit else { return [] }
        let startup = inventory.devices.flatMap(\.containers).flatMap(\.volumes).first { $0.mountPoint == "/" }
        return [storageFinding(.staleSnapshots, name: startup?.name, at: time,
                               evidence: .init(limit: rule.limit, peak: age, mean: age), thresholds: thresholds)]
    }

    /// - Parameter name: Name des Volumes oder Datenträgers; `nil` ohne Bezug.
    private static func storageFinding(_ kind: SystemFinding.Kind, name: String?, at time: Date,
                                       evidence: SystemFinding.Evidence,
                                       thresholds: FindingThresholds) -> SystemFinding {
        let tone = Self.tone(of: thresholds.rule(for: kind), peak: evidence.peak)
        // Schon hier begrenzt (Spec §4.5), damit der Grund denselben Namen nennt wie der Bezug.
        let subject = name.map { SystemFinding.Subject.volume(name: SystemFinding.limited($0)) }
        return SystemFinding(kind: kind, tone: tone,
                             reason: reason(for: kind, tone: tone, subject: subject, thresholds: thresholds),
                             start: time, end: nil, evidence: evidence, subject: subject)
    }

    /// Das Volume, nach dem ein Container heißt: System vor Daten vor gewöhnlichem Volume, nur eingehängte.
    private static func userVolume(of container: APFSContainer) -> APFSVolume? {
        let mounted = container.volumes.filter { $0.mountPoint != nil }
        return mounted.first { $0.role == .system } ?? mounted.first { $0.role == .data }
            ?? mounted.first { $0.role == nil }
    }

    /// Belegter Anteil 0…1; `nil` ohne Kapazität.
    private static func usedShare(of container: APFSContainer) -> Double? {
        let (total, free): (Int64, Int64) = if let usage = container.usage {
            (usage.totalBytes, usage.importantUsageAvailableBytes ?? usage.availableBytes)
        } else {
            (container.capacityBytes, container.freeBytes)
        }
        guard total > 0 else { return nil }
        return Double(min(max(total - free, 0), total)) / Double(total)
    }

    // MARK: Texte

    static func volumeDisplayName(_ subject: SystemFinding.Subject?) -> String? {
        guard case .volume(let name)? = subject else { return nil }
        return name
    }

    static func daysText(_ seconds: TimeInterval) -> String {
        let days = Int((seconds / 86_400).rounded())
        guard days >= 1 else { return AppUsagePresentation.durationText(seconds) }
        return days == 1 ? "1 Tag" : "\(days) Tage"
    }
}

extension SystemFinding.Kind {
    /// Datenträger-Befund aus dem Volume-Inventar (`FindingRules.storageFindings`).
    public var isStorage: Bool {
        switch self {
        case .volumeFull, .smartFailure, .staleSnapshots: true
        default: false
        }
    }
}

extension SystemFinding {
    /// Gleicher Befund über mehrere Prüfungen: gleiche Art, gleicher Bezug.
    func matches(_ other: SystemFinding) -> Bool { kind == other.kind && subject == other.subject }
}
