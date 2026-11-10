extension ActionConfirmation {
    /// „Starten“ im Tab „Dienste“ (`launchctl kickstart`).
    public static func startService(_ item: AutostartItem) -> ActionConfirmation {
        ActionConfirmation(title: "„\(item.label)“ starten?", message: serviceDetails(item), confirmTitle: "Starten",
                           isDestructive: false)
    }

    /// „Stoppen“ (`launchctl kill SIGTERM`); die launchd-Konfiguration bleibt unverändert.
    public static func stopService(_ item: AutostartItem) -> ActionConfirmation {
        ActionConfirmation(
            title: "„\(item.label)“ stoppen?",
            message: serviceDetails(item),
            note: "launchd beendet den Dienst mit SIGTERM; ungesicherte Daten können verloren gehen. Ist er auf "
                + "Dauerbetrieb eingestellt (KeepAlive), startet launchd ihn gleich wieder – dauerhaft abschalten lässt "
                + "er sich im Bereich „Autostart“.",
            confirmTitle: "Stoppen",
            isDestructive: true
        )
    }

    private static func serviceDetails(_ item: AutostartItem) -> String {
        ["Plist: \(item.plistPath.map { PathDisplay.abbreviatingHome($0) } ?? "–")", "Programm: \(item.program ?? "–")"]
            .joined(separator: "\n")
    }
}
