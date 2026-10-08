import Foundation

/// Lauscher, die aus dem Netz erreichbar sind (Spec §7). Mittel: kein Dienst von macOS. Hoch: zusätzlich
/// unsigniert/ad hoc, ein Interpreter, ein Netzwerkwerkzeug (`NetworkTool`, etwa `nc -l`) oder ein Programm an einem
/// beschreibbaren Ort. Kein Fund: nur Loopback, Dienste von macOS (`NetworkListener.isAppleService`; Interpreter und
/// Netzwerkwerkzeuge zählen nie dazu, auch Apple-signiert) und vermutliche Clients (`NetworkListener.isBenignClientUDP`:
/// UDP auf wechselndem Port oder mDNS eines regulär signierten Programms).
public struct ExposedListenerRule: RiskRule {
    private let writablePrefixes: [String]

    public init(home: String = NSHomeDirectory()) {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        writablePrefixes = [
            "/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/var/folders/", "/private/var/folders/",
            "/Users/Shared/", home + "/Downloads/",
        ]
    }

    public func evaluate(_ snapshot: Snapshot) -> [RiskFinding] {
        snapshot.networkListeners.compactMap { listener in
            guard let assessment = assess(listener) else { return nil }
            let reasons = assessment.reasons.isEmpty ? "" : " – " + assessment.reasons.joined(separator: ", ")
            return RiskFinding(
                rule: .exposedListener, severity: assessment.severity, recordID: listener.id,
                message: "\(listener.processName) ist von außen erreichbar (\(listener.portLabel))\(reasons)"
            )
        }
    }

    private struct Assessment {
        let severity: RiskFinding.Severity
        let reasons: [String]
    }

    private func assess(_ listener: NetworkListener) -> Assessment? {
        guard listener.reachability.isExposed, !listener.isAppleService, !listener.isBenignClientUDP else { return nil }
        var reasons: [String] = []
        if ScriptInterpreter.matches(listener.executablePath) { reasons.append("Interpreter") }
        if NetworkTool.matches(listener.executablePath) { reasons.append("Netzwerkwerkzeug") }
        if [.unsigned, .adHoc].contains(listener.signing.kind) { reasons.append("nicht regulär signiert") }
        if writablePrefixes.contains(where: listener.executablePath.hasPrefix) { reasons.append("beschreibbarer Ort") }
        return Assessment(severity: reasons.isEmpty ? .medium : .high, reasons: reasons)
    }
}
