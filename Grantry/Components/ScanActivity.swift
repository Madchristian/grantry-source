import ManagerKit

/// Was ein laufender Monitoring-Vollscan („Aktualisieren“) im Hauptfenster bewirkt (#238, #262, #270): Er sperrt nur den
/// Toolbar-Button, ohne Balken. Die Leisten über den Tabellen von „Aufräumen“ zeigen ausschließlich den Scan ihres
/// Segments (`SegmentScanProgress`), damit ein Vollscan nicht wie ein Fortschritt des gedrückten „Scannen“ aussieht. Die
/// Signaturprüfung nach dem Vollscan zeigt der Button als Text, ohne Sperre.
struct ScanActivity: Equatable {
    let isScanButtonEnabled: Bool

    init(_ state: MonitoringState) {
        isScanButtonEnabled = !state.isScanning
    }
}
