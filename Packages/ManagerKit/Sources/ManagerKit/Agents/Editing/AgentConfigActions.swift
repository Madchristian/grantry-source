import Foundation

/// Ergebnis von `AgentConfigControlling.restore(changeID:)`.
public enum AgentRestoreResult: Hashable, Sendable {
    /// Die Datei war seit der Änderung unverändert: gesicherte Fassung zurückgelegt.
    case restoredFile
    /// Die Datei hatte sich geändert: nur den Server wieder eingetragen bzw. den Schalter zurückgestellt.
    case revertedEntry
    /// Der Server stand bereits wieder so in der Datei; nichts geändert.
    case alreadyRestored
}

/// Ändert MCP-Server in Agenten-Konfigurationen; in der App `AgentConfigActions`.
public protocol AgentConfigControlling: Sendable {
    func removeServer(_ entry: MCPServerEntry) async throws -> AgentConfigChange
    func setEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async throws -> AgentConfigChange
    func restore(changeID: UUID) async throws -> AgentRestoreResult
}

/// „Server entfernen …“, „Deaktivieren“/„Aktivieren“ und „Wiederherstellen“ für MCP-Server (Spec Stufe 2), im
/// Benutzerkontext ohne Helper.
///
/// Jede Änderung: Bereich prüfen (`AgentEditCapabilities`), Datei frisch und gehärtet lesen (`AgentConfigFileAccess`),
/// neuen Inhalt berechnen und nachprüfen (`AgentConfigEditor` – der Server muss unverändert vorhanden sein), die ganze
/// Datei sichern samt Beleg (`AgentConfigBackupStore`), atomar ersetzen, wenn sie sich seit dem Lesen nicht geändert
/// hat. Scheitert das Ersetzen, ohne die Datei zu ändern (`leavesFileUnchanged`), wird die Sicherung wieder gelöscht,
/// und ältere Sicherungen derselben Datei bleiben; aufgeräumt wird erst nach dem Ersetzen. Steht die neue Fassung
/// trotz gescheiterter Nachprüfung in der Datei (`replacedUnverified`), bleiben Sicherung und Beleg erhalten und
/// erscheinen im Verlauf – der Fehler wird trotzdem gemeldet.
///
/// Wiederherstellen: Ist die Datei seit der Änderung unverändert (Prüfsumme = `resultDigest`), wird die gesicherte
/// Fassung byte-genau zurückgelegt. Sonst wird nur der Server aus der Sicherung wieder eingefügt bzw. der Schalter
/// zurückgestellt – so gehen spätere Änderungen anderer (etwa der Tools selbst) nicht verloren. Danach wird der Beleg
/// samt Sicherung gelöscht.
///
/// Der Beleg ist nur so vertrauenswürdig wie seine Ablage. Deshalb wird sein Ziel – bewusst auch vor dem byte-genauen
/// Zurücklegen, das den Katalog fachlich nicht bräuchte – wie bei jeder Änderung über Bereich und Katalog aufgelöst
/// (`AgentEditCapabilities`), und ein Projekt muss in der aktuellen Registerdatei stehen: Ein manipulierter Beleg kann
/// so nur Dateien betreffen, die Grantry ohnehin ändern dürfte. Die Registerdatei eines Servers aus einer Projektdatei
/// (`.mcp.json`) wird dabei nur gelesen, nicht geändert – deshalb wie im Scan (`AgentConfigReader`: Symlinks innerhalb
/// des Benutzerordners erlaubt, Größengrenze) statt mit den strengen Regeln fürs Ersetzen, und bevor die Projektdatei
/// überhaupt geöffnet wird.
public struct AgentConfigActions: AgentConfigControlling {
    private let catalog: AgentToolCatalog
    private let home: String
    private let backups: AgentConfigBackupStore
    private let now: @Sendable () -> Date
    private let fingerprinter: SecretFingerprinter
    private let replace: Replace

    /// Ersetzt die gelesene Datei durch den neuen Inhalt – `AgentConfigFileAccess.replace`, in Tests austauschbar.
    typealias Replace = @Sendable (ConfigFileSnapshot, Data) throws(AgentConfigEditError) -> Void

    /// - Parameter fingerprinter: derselbe Schlüssel wie im Scan (`StandardSources`), damit die Vorbedingung vor dem
    ///   Ändern auch verborgene Befehle vergleichen kann (`MCPServerEntry.hasSameTransport`).
    public init(
        catalog: AgentToolCatalog = .standard, home: String = NSHomeDirectory(),
        backups: AgentConfigBackupStore = StorageLocation.standard.agentBackups,
        now: @escaping @Sendable () -> Date = Date.init, fingerprinter: SecretFingerprinter = .processLocal
    ) {
        self.init(
            catalog: catalog, home: home, backups: backups, now: now, fingerprinter: fingerprinter
        ) { snapshot, contents throws(AgentConfigEditError) in
            try AgentConfigFileAccess.replace(snapshot, with: contents)
        }
    }

    init(
        catalog: AgentToolCatalog, home: String, backups: AgentConfigBackupStore, now: @escaping @Sendable () -> Date,
        fingerprinter: SecretFingerprinter = .processLocal, replace: @escaping Replace
    ) {
        self.catalog = catalog
        self.home = home
        self.backups = backups
        self.now = now
        self.fingerprinter = fingerprinter
        self.replace = replace
    }

    public func removeServer(_ entry: MCPServerEntry) async throws -> AgentConfigChange {
        try change(entry, .remove, kind: .removedServer)
    }

    public func setEnabled(_ entry: MCPServerEntry, _ enabled: Bool) async throws -> AgentConfigChange {
        try change(entry, .setEnabled(enabled), kind: .setEnabled(enabled))
    }

    /// Legt die Sicherung zurück, wenn die Datei seit der Änderung unverändert ist, sonst nimmt sie nur den Eintrag
    /// zurück (Spec §6). Danach – auch bei `alreadyRestored` – verschwinden Beleg und Sicherung.
    ///
    /// Die Prüfung „steht schon so“ ist bewusst asymmetrisch: Ein entfernter Server gilt nur als wiederhergestellt,
    /// wenn sein Quelltext byte-gleich dem aus der Sicherung ist – erst dann stehen seine Werte (auch Geheimnisse) in
    /// der Datei, und die Sicherung darf weg; ein anderer Eintrag unter dem Namen bricht ab (`nameTaken`), die
    /// Sicherung bleibt. Bei einem Schalter genügt dagegen, dass er schon den früheren Zustand hat, auch wenn sich der
    /// Rest der Datei geändert hat: Die Sicherung dient nur dem Zurückstellen dieses Schalters und bewahrt nichts,
    /// was sonst verloren wäre. Der Server selbst muss aber noch der gesicherte sein (Befehl samt Argumenten bzw. URL,
    /// `AgentConfigEditor.revertSwitch`): Ein alter Beleg darf keinen inzwischen unter demselben Namen ersetzten Server
    /// anstellen – auch dann `nameTaken`, die Sicherung bleibt. Zurückgestellt wird, indem der frühere Wert geschrieben
    /// wird (`enabled = true`), nicht indem ein beim Deaktivieren eingefügter Schlüssel wieder entfernt wird.
    public func restore(changeID: UUID) async throws -> AgentRestoreResult {
        guard let change = backups.change(id: changeID) else { throw AgentConfigEditError.changeNotFound }
        let target = try checkedTarget(for: change.server, isEnabled: nil)
        let original = try backups.original(of: change)
        if let registryPath = change.server.registryPath {
            try ensureProjectRegistered(target, inRegistryAt: registryPath)
        }
        let snapshot = try AgentConfigFileAccess.read(change.server.configPath, home: home)
        if change.server.registryPath == nil {
            try ensureProjectRegistered(target, in: snapshot.contents)
        }
        let editor = AgentConfigEditor(target: target, fingerprinter: fingerprinter)
        let restored: Data
        let result: AgentRestoreResult
        do {
            if snapshot.digest == change.resultDigest {
                (restored, result) = (original, .restoredFile)
            } else {
                switch change.kind {
                case .removedServer:
                    restored = try editor.reinsert(from: original, into: snapshot.contents)
                case .setEnabled(let enabled):
                    restored = try editor.revertSwitch(to: !enabled, from: original, into: snapshot.contents)
                }
                result = .revertedEntry
            }
        } catch AgentConfigEditError.alreadyInState {
            backups.delete(id: changeID)
            return .alreadyRestored
        }
        try replace(snapshot, restored)
        backups.delete(id: changeID)
        return result
    }

    // MARK: Ablauf

    private func change(_ entry: MCPServerEntry, _ operation: AgentConfigEditor.Operation, kind: AgentConfigChange.Kind) throws -> AgentConfigChange {
        let editor = AgentConfigEditor(
            target: try checkedTarget(for: entry.reference, isEnabled: entry.isEnabled), fingerprinter: fingerprinter
        )
        let snapshot = try AgentConfigFileAccess.read(entry.configPath, home: home)
        let updated = try editor.apply(operation, expected: entry, to: snapshot.contents)
        let change = AgentConfigChange(
            id: UUID(), kind: kind, server: entry.reference, changedAt: now(), originalDigest: snapshot.digest,
            resultDigest: AgentConfigFileAccess.digest(of: updated)
        )
        try backups.save(change, original: snapshot.contents)
        do {
            try replace(snapshot, updated)
        } catch {
            // Nur eine nachweislich unveränderte Datei braucht keine Sicherung mehr.
            if error.leavesFileUnchanged { backups.delete(id: change.id) } else { backups.commit(change) }
            throw error
        }
        backups.commit(change)
        return change
    }

    /// Das Ziel des Servers, wenn `AgentEditCapabilities` die Änderung erlaubt; sonst `ActionError.notAllowed` mit
    /// demselben Grund, den die Oberfläche beim Schloss nennt (eine Quelle für beide Texte). Kennt der Katalog Tool oder
    /// Datei nicht, ist das wie dort `unknownConfiguration`.
    private func checkedTarget(for reference: AgentServerReference, isEnabled: Bool?) throws -> AgentServerTarget {
        let target = try? AgentServerTarget(reference: reference, catalog: catalog, home: home)
        let capabilities = AgentEditCapabilities(reference: reference, isEnabled: isEnabled, target: target, home: home)
        if case .readOnly(let reason) = capabilities.availability { throw ActionError.notAllowed(reason) }
        // Ohne Ziel ist die Verfügbarkeit nie `.available` – nur der Vollständigkeit halber.
        guard let target else { throw ActionError.notAllowed(.unknownConfiguration) }
        return target
    }

    /// Projektserver aus einer Projektdatei: Das Projekt muss in der Registerdatei unter `path` stehen – gelesen wie im
    /// Scan, bevor die Projektdatei geöffnet wird; Fehler nennen die Registerdatei.
    private func ensureProjectRegistered(_ target: AgentServerTarget, inRegistryAt path: String) throws(AgentConfigEditError) {
        let registry: Data
        switch AgentConfigReader.read(path: path, home: AgentConfigReader.Home(home)) {
        case .contents(let data, _): registry = data
        case .missing: throw .notEditable("Die Registerdatei \(path) fehlt")
        case .unreadable(let reason): throw .unreadable("Registerdatei \(path): \(reason)")
        }
        do {
            try ensureProjectRegistered(target, in: registry)
        } catch .unreadable(let reason) {
            throw .unreadable("Registerdatei \(path): \(reason)")
        }
    }

    /// Projektserver: Das Projekt muss in `registry` (Inhalt der Registerdatei) stehen, sonst `notEditable`, ohne etwas
    /// zu ändern; außerhalb von Projekten immer erfüllt.
    private func ensureProjectRegistered(_ target: AgentServerTarget, in registry: Data) throws(AgentConfigEditError) {
        guard try target.isProjectRegistered(in: registry) else { throw .notEditable("Das Projekt ist Grantry nicht bekannt") }
    }
}
