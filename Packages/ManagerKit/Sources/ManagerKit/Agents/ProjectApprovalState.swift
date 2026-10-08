/// Freigabe der Server einer Projektdatei (`.mcp.json`), zusammengeführt aus mehreren Quellen: Projektobjekt der
/// Registerdatei und Einstellungsdateien des Projekts (geteilt, lokal); die Reihenfolge spielt keine Rolle. Rein.
///
/// - Namenslisten werden über alle Quellen vereinigt – wie Claude Code Array-Einstellungen über Ebenen zusammenführt.
/// - „Alle freigeben“ gilt, sobald irgendeine Quelle es setzt.
/// - Abgelehnt schlägt freigegeben, auch „alle freigeben“.
struct ProjectApprovalState: Equatable {
    private var enabledNames: Set<String> = []
    private var disabledNames: Set<String> = []
    private var enablesAll = false

    /// Nimmt die Angaben aus `settings` (unter `paths`) zum bisherigen Stand hinzu.
    func overlaid(with settings: ConfigValue, paths: some ProjectServerApprovalPaths) -> ProjectApprovalState {
        var state = self
        state.enabledNames.formUnion(settings.strings(at: paths.enabledNamesPath))
        state.disabledNames.formUnion(settings.strings(at: paths.disabledNamesPath))
        state.enablesAll = enablesAll || paths.enableAllPath.flatMap { settings.value(at: $0)?.bool } == true
        return state
    }

    /// `false` bei Ablehnung, `true` bei Freigabe (einzeln oder alle), sonst `nil` – Freigabe ausstehend.
    func isEnabled(_ name: String) -> Bool? {
        if disabledNames.contains(name) { return false }
        return enablesAll || enabledNames.contains(name) ? true : nil
    }
}
