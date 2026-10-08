import Foundation
import Synchronization

/// Lauscher, deren Prozesse Grantry eben beendet hat („Prozess beenden …“, #128). Ohne Vermerk bliebe ein beendeter
/// Lauscher wegen der Entprellung (`Snapshot.carryingForwardListeners`) 5 bzw. 20 Minuten – fremde ohne Helper
/// unbegrenzt – in der Liste, und die Wirkungsprüfung der Aktion bliebe unbestätigt. Ein Referenztyp: App,
/// `NetworkListenerSource` und `ProcessTerminator` teilen ein Exemplar.
///
/// Ein Vermerk endet, sobald der Lauscher wieder gesehen wird (Neustart über Autostart) oder nach `retention`
/// (danach entfiele er auch ohne Vermerk). Er verhindert nur das Fortschreiben: Ein Lauscher im aktuellen Scan bleibt
/// immer sichtbar, ein Neustart des Dienstes macht ihn also nie unsichtbar.
///
/// Bewusste Grenze: Startet ein fremder Dienst neu, während die Quelle nur lokal (ohne Helper) liest, sieht ihn erst
/// die nächste Helper-Abfrage. Er fehlt bis dahin – bis zu 15 min (`ListenerTiming.helperInterval`) – und erscheint
/// dann als neu (`.added`).
public final class ListenerTerminationLedger: Sendable {
    private struct State {
        var ended: [String: Date] = [:]
        var needsHelperRefresh = false
    }

    private let state = Mutex(State())
    private let retention: TimeInterval

    public convenience init() {
        self.init(retention: Snapshot.foreignListenerGracePeriod)
    }

    init(retention: TimeInterval) {
        self.retention = retention
    }

    /// Vermerkt den Lauscher als beendet; der nächste Scan der Quelle fragt den Helper sofort.
    public func record(_ listenerID: String, at date: Date) {
        state.withLock { state in
            state.ended[listenerID] = date
            state.needsHelperRefresh = true
        }
    }

    /// Bereinigt die Vermerke und liefert die beendeten Lauscher, die nicht fortgeschrieben werden dürfen. Dabei
    /// entfallen abgelaufene Vermerke und solche, deren Lauscher die Messung wieder gesehen hat (`seen`).
    ///
    /// - Parameter date: Beginn der Messung, also vor dem Lesen der Sockets erfasst. Eine Sichtung hebt nur Vermerke
    ///   auf, die vor diesem Zeitpunkt lagen: Ein Scan, der die Sockets las, solange der Prozess noch lief, und erst
    ///   nach dem Vermerk abschließt, darf ihn nicht löschen. Ein späterer Vermerk gilt auch nicht als abgelaufen.
    func settleEndedIDs(at date: Date, seen: Set<String>) -> Set<String> {
        state.withLock { state in
            state.ended = state.ended.filter { id, recordedAt in
                (recordedAt > date || !seen.contains(id)) && date.timeIntervalSince(recordedAt) <= retention
            }
            return Set(state.ended.keys)
        }
    }

    /// Einmal `true` nach `record`: Die Quelle fragt dann den Helper außerhalb ihres Takts.
    func takeHelperRefresh() -> Bool {
        state.withLock { state in
            defer { state.needsHelperRefresh = false }
            return state.needsHelperRefresh
        }
    }
}
