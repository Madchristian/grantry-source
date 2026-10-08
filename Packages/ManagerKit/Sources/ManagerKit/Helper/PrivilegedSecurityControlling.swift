/// Absichernde Operationen des root-Helpers (Spec v2): nur einschalten, nie abschalten. Wie bei
/// `PrivilegedAutostartControlling` gilt: Scheitert ein Aufruf nach dem Senden, ist das Ergebnis unbekannt –
/// Aufrufer prüfen per Neu-Scan.
public protocol PrivilegedSecurityControlling: Sendable {
    /// Protokollversion des laufenden Helpers; ein älterer kennt die absichernden Operationen nicht.
    /// - Throws: wie `perform(_:)`.
    func protocolVersion() async throws -> Int

    /// Führt die festen Befehle von `hardening` im Helper aus.
    /// - Throws: `HelperClientError.rejected` mit der Meldung des ersten gescheiterten Befehls,
    ///   `HelperClientError.unavailable` ohne Verbindung oder bei Zeitüberschreitung, `CancellationError`.
    func perform(_ hardening: SecurityHardening) async throws
}
