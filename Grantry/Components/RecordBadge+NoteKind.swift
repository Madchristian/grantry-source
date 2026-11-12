import GrantryCharts
import ManagerKit

extension RecordBadge {
    /// Art der Hinweiszeile: hoher Schweregrad als Fehler, sonst auffällig mit Befund-Punkt.
    var noteKind: InstrumentNote.Kind {
        tone == .critical ? .critical : .finding
    }
}
