import Foundation

/// Parser für die Textausgabe von `launchctl`.
///
/// Die Block-Parser werten nur ihren Block aus und liefern `nil`, wenn dessen Kopf fehlt: Ein leeres Ergebnis bei
/// verändertem Ausgabeformat würde jeden Eintrag als geladen/aktiv bzw. entladen umkippen lassen.
enum LaunchctlParsers {
    /// `launchctl print-disabled <domain>` → Label : istDeaktiviert, aus dem Block `disabled services = { … }`.
    /// Eine Domain ohne Overrides liefert den Kopf mit leerem Rumpf und damit ein leeres Dictionary.
    static func disabledOverrides(_ output: String) -> [String: Bool]? {
        guard let lines = blockLines(in: output, header: "disabled services = {") else { return nil }
        var result: [String: Bool] = [:]
        for line in lines {
            let parts = line.split(separator: "=>", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch parts[1].trimmingCharacters(in: .whitespaces) {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// `launchctl print <domain>` → Labels im Block `services = { … }`.
    static func loadedLabels(_ output: String) -> Set<String>? {
        guard let lines = blockLines(in: output, header: "services = {") else { return nil }
        // Dritte Spalte (nach PID und Exit-Status) als Label nehmen, ohne bei Leerzeichen im Label
        // (z. B. „Discord Helper.79735“) weiter aufzusplitten.
        return Set(lines.compactMap { line in
            line.split(maxSplits: 2, whereSeparator: \.isWhitespace).last.map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }

    /// Getrimmte, nicht leere Zeilen zwischen der Zeile `header` (exakt, nach Trimmen) und der nächsten `}`;
    /// `nil`, wenn `header` fehlt.
    private static func blockLines(in output: String, header: String) -> [String]? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(of: header) else { return nil }
        let body = lines[(start + 1)...]
        return Array(body.prefix { $0 != "}" }.filter { !$0.isEmpty })
    }
}
