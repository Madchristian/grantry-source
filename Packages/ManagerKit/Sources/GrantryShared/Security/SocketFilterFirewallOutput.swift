import Foundation

/// Auswertung der Ausgabe von `socketfilterfw --getglobalstate` und `--getstealthmode` – die einzige Stelle dafür.
/// App (Anzeige des Zustands) und Helper (Vorab-Abfrage vor dem Setzen) bewerten damit denselben Text gleich.
///
/// Jede Funktion sucht ihre Angabe in der gesamten Ausgabe, deshalb geht sowohl der gemeinsame Aufruf beider Befehle als
/// auch die Ausgabe eines einzelnen Befehls. Eine fehlende oder unbekannte Angabe ergibt `nil` – nie eine Vermutung.
public enum SocketFilterFirewallOutput {
    /// Globaler Zustand der Firewall. Maßgeblich ist die Zahl in „Firewall is enabled. (State = 1)“: `0` aus, `1` an,
    /// `2` alle eingehenden Verbindungen blockieren. Jeder Wert ≠ 0 gilt als eingeschaltet. Meldet macOS „alle
    /// blockieren“ zusätzlich getrennt (`--getblockall`), steht der globale Zustand trotzdem nicht auf `0`.
    public static func isEnabled(in output: String) -> Bool? {
        lines(of: output).lazy.compactMap(globalState).first.map { $0 != 0 }
    }

    /// Tarnmodus: „Firewall stealth mode is on“ bzw. „… is off“.
    public static func isStealthModeOn(in output: String) -> Bool? {
        lines(of: output).lazy.compactMap { line -> Bool? in
            switch line {
            case "Firewall stealth mode is on": true
            case "Firewall stealth mode is off": false
            default: nil
            }
        }.first
    }

    /// Zahl aus „Firewall is enabled. (State = 1)“ bzw. „Firewall is disabled. (State = 0)“.
    private static func globalState(in line: String) -> Int? {
        guard line.hasPrefix("Firewall is"), let match = line.firstMatch(of: /\(State = (\d+)\)/) else { return nil }
        return Int(match.1)
    }

    private static func lines(of output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
