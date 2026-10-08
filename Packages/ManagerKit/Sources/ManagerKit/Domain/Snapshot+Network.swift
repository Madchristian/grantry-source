import Foundation

extension Snapshot {
    /// Wie lange ein nicht mehr gesehener eigener Lauscher fortgeschrieben wird, bevor er als entfernt gilt:
    /// Dev-Server, die neu starten, sollen weder „entfernt“ noch „neu“ melden.
    static let listenerGracePeriod: TimeInterval = 5 * 60
    /// Dasselbe für Lauscher anderer Benutzer: Helper-Takt (`ListenerTiming.helperInterval`, 15 min) plus
    /// `listenerGracePeriod`. Ihre Sockets liest nur der Helper, ihr `lastSeenAt` wird daher höchstens einmal je Takt
    /// aufgefrischt. Weil Teilscans im 60-s-Raster laufen, liegt der reale Helper-Takt bei 15–16 min: Mit 20 min
    /// übersteht ein verschwundener fremder Lauscher genau einen Helper-Scan und gilt nach etwa 30 min als entfernt.
    static let foreignListenerGracePeriod: TimeInterval = ListenerTiming.helperInterval + listenerGracePeriod

    /// Schreibt Lauscher aus `previous` fort (Spec §4):
    /// - wieder gesehene behalten ihr früheres `firstSeenAt`,
    /// - fehlende eigene (`uid == currentUID`) bleiben, solange ihr `lastSeenAt` höchstens `listenerGracePeriod` vor
    ///   `takenAt` liegt, fehlende fremde höchstens `foreignListenerGracePeriod`,
    /// - mit `isLimited` (nur eigene Sockets lesbar) bleiben fehlende Lauscher anderer Benutzer unabhängig vom Alter –
    ///   als letzter bekannter Zustand wie bei `carryingForwardRecords(ofFailedSourcesFrom:)`; die Einschränkung ist in
    ///   der Oberfläche sichtbar. Fehlt der Helper dauerhaft, bleiben sie also stehen, bis er wieder liest,
    /// - springt die Uhr zurück (`takenAt` vor `lastSeenAt`), bleibt ein fehlender Lauscher, bis die Uhr aufgeholt hat,
    /// - doppelte IDs in `previous` werden nur einmal angehängt (der erste gewinnt),
    /// - in `ended` vermerkte (von Grantry beendete) Lauscher fallen sofort weg.
    ///
    /// Idempotent: Erneutes Anwenden mit demselben Vorgänger ändert nichts.
    func carryingForwardListeners(
        from previous: Snapshot?, currentUID: UInt32, isLimited: Bool, ended: Set<String> = []
    ) -> Snapshot {
        guard let previous else { return self }
        let previousByID = previous.networkListeners.firstByID()
        var result = self
        result.networkListeners = networkListeners.map { listener in
            guard let earlier = previousByID[listener.id] else { return listener }
            var listener = listener
            listener.firstSeenAt = min(listener.firstSeenAt, earlier.firstSeenAt)
            return listener
        }
        var handled = Set(networkListeners.map(\.id))
        result.networkListeners += previous.networkListeners.filter { listener in
            guard handled.insert(listener.id).inserted else { return false }
            guard !ended.contains(listener.id) else { return false }
            guard listener.uid == currentUID else {
                return isLimited || isWithin(Self.foreignListenerGracePeriod, since: listener.lastSeenAt)
            }
            return isWithin(Self.listenerGracePeriod, since: listener.lastSeenAt)
        }
        return result
    }

    /// `true`, wenn `date` höchstens `interval` vor `takenAt` liegt (oder danach).
    private func isWithin(_ interval: TimeInterval, since date: Date) -> Bool {
        takenAt.timeIntervalSince(date) <= interval
    }
}
