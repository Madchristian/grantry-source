/// Netzspalte des Task-Managers (Spec 2026-11-06 §2, §3: „Netz je Prozess – vorhanden, `NettopSampler`“).
extension NetworkActivityModel {
    /// Empfangen + Senden je Prozess (Byte/s, geglättet wie in „Aktivität“); `nil`, solange keine Rate vorliegt –
    /// nettop läuft nicht, ist ausgefallen oder hat erst die Basis gemessen. Prozesse ohne Zeile senden nichts.
    public var processRates: [ProcessKey: Double]? { Self.processRates(status: status, report: frame.report) }

    static func processRates(status: Status, report: TrafficReport) -> [ProcessKey: Double]? {
        guard status == .running, !report.history.isEmpty else { return nil }
        let active = report.processes.filter { !$0.isGone }
        return Dictionary(active.map { ($0.key, $0.rate.total) }, uniquingKeysWith: +)
    }
}
