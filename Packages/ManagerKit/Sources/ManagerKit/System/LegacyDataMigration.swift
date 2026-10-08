import AppKit
import os

/// Übernimmt einmalig die Daten der App aus der Zeit, als sie noch „MacManager“ hieß (bis 2026-09-27).
///
/// - Ablageort: Existiert `~/Library/Application Support/MacManager`, der neue Ablageort aber noch nicht, wird der
///   alte Ordner als Ganzes verschoben (Verlauf samt `-wal`/`-shm`, Wiederherstellungsbelege, Benutzer-Backups; die
///   Instanzsperre wandert mit und ist bedeutungslos). Läuft die alte App noch, wird sie zum Beenden aufgefordert – sie
///   schriebe sonst über offene Dateien weiter in den verschobenen Verlauf. Beendet sie sich nicht rechtzeitig, wird
///   nichts verschoben und der Aufrufer darf den neuen Ablageort nicht anlegen (sonst gälte die Übernahme beim
///   nächsten Start als erledigt). Schlägt das Verschieben fehl, beginnt die App mit leerem Ablageort; der alte
///   Ordner bleibt unangetastet und wird nie gelöscht.
/// - `UserDefaults`: Die Schlüssel aus `migratedDefaultsKeys` werden aus der alten Domain übernommen, sofern sie in
///   der neuen noch fehlen. Vorhandene Werte werden nie überschrieben, daher ist die Übernahme idempotent.
///
/// Die System-Backups des alten Helpers (`/Library/Application Support/MacManager/Backups`) übernimmt diese Einheit
/// nicht (root-eigen); siehe `docs/umstieg-von-macmanager.md`.
public struct LegacyDataMigration {
    /// Ergebnis der Übernahme des Ablageorts.
    public enum StorageOutcome: Equatable, Sendable {
        /// Kein alter Ablageort vorhanden.
        case nothingToMigrate
        /// Der neue Ablageort existiert bereits; der alte bleibt unberührt.
        case alreadyMigrated
        /// Der alte Ablageort wurde an den neuen verschoben.
        case moved
        /// Die alte App hat sich nicht beendet; nichts wurde verschoben. Der Aufrufer darf nicht weiterstarten.
        case legacyAppRunning
        /// Das Verschieben schlug fehl; die App beginnt mit leerem Ablageort, der alte bleibt erhalten.
        case failed(String)
    }

    /// Bundle-ID der App unter ihrem alten Namen; zugleich Name ihrer `UserDefaults`-Domain.
    public static let legacyBundleID = "de.cstrube.MacManager"
    /// Ordnername des alten Ablageorts in `~/Library/Application Support`.
    public static let legacyDirectoryName = "MacManager"
    /// Einstellungen, die übernommen werden. Fenster- und Spaltengrößen legt das System neu an.
    public static let migratedDefaultsKeys = [OnboardingModel.completedKey]

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "migration")

    private let legacyDirectory: URL
    private let currentDirectory: URL
    private let legacyDefaults: (any SettingsStore)?
    private let defaults: any SettingsStore
    private let fileManager: FileManager
    private let isLegacyAppRunning: () -> Bool
    private let quitLegacyApp: () -> Void
    private let quitTimeout: Duration
    private let move: (URL, URL) throws -> Void

    /// - Parameter isLegacyAppRunning: ob die App unter ihrem alten Namen läuft (Standard: laufende Anwendungen mit
    ///   `legacyBundleID`); für Tests austauschbar.
    /// - Parameter quitLegacyApp: fordert die alte App zum Beenden auf (Standard: `NSRunningApplication.terminate()`).
    /// - Parameter quitTimeout: wie lange auf das Beenden der alten App gewartet wird.
    /// - Parameter move: verschiebt einen Ordner (Standard: `FileManager.moveItem(at:to:)`); für Tests austauschbar.
    public init(
        legacyDirectory: URL,
        currentDirectory: URL,
        legacyDefaults: (any SettingsStore)?,
        defaults: any SettingsStore,
        fileManager: FileManager = .default,
        isLegacyAppRunning: (() -> Bool)? = nil,
        quitLegacyApp: (() -> Void)? = nil,
        quitTimeout: Duration = .seconds(15),
        move: ((URL, URL) throws -> Void)? = nil
    ) {
        self.legacyDirectory = legacyDirectory
        self.currentDirectory = currentDirectory
        self.legacyDefaults = legacyDefaults
        self.defaults = defaults
        self.fileManager = fileManager
        self.isLegacyAppRunning = isLegacyAppRunning ?? { !Self.runningLegacyApps.isEmpty }
        self.quitLegacyApp = quitLegacyApp ?? { Self.runningLegacyApps.forEach { $0.terminate() } }
        self.quitTimeout = quitTimeout
        self.move = move ?? { try fileManager.moveItem(at: $0, to: $1) }
    }

    /// Übernahme vom alten in den Standard-Ablageort (`StorageLocation.standard`) und in `UserDefaults.standard`.
    public static var standard: LegacyDataMigration {
        LegacyDataMigration(
            legacyDirectory: URL.applicationSupportDirectory.appending(path: legacyDirectoryName, directoryHint: .isDirectory),
            currentDirectory: StorageLocation.standard.directory,
            legacyDefaults: UserDefaults(suiteName: legacyBundleID),
            defaults: UserDefaults.standard
        )
    }

    private static var runningLegacyApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID)
    }

    /// Führt beide Übernahmen aus und protokolliert das Ergebnis. Muss vor dem ersten Zugriff auf den Ablageort laufen;
    /// bei `.legacyAppRunning` darf die App nicht weiterstarten.
    @discardableResult
    public func run() -> StorageOutcome {
        let outcome = migrateStorage()
        switch outcome {
        case .nothingToMigrate, .alreadyMigrated:
            break
        case .legacyAppRunning:
            Self.logger.error("MacManager hat sich nicht beendet – Daten nicht übernommen")
        case .moved:
            Self.logger.notice("Daten aus \(legacyDirectory.path, privacy: .public) übernommen")
        case .failed(let reason):
            Self.logger.error("""
                Daten aus \(legacyDirectory.path, privacy: .public) nicht übernommen (\(reason, privacy: .public)); \
                beginne mit leerem Ablageort, der alte Ordner bleibt erhalten
                """)
        }
        let keys = migrateDefaults()
        if !keys.isEmpty {
            Self.logger.notice("Einstellungen übernommen: \(keys.joined(separator: ", "), privacy: .public)")
        }
        return outcome
    }

    /// Verschiebt den alten Ablageort an den neuen, wenn nur der alte existiert.
    @discardableResult
    public func migrateStorage() -> StorageOutcome {
        guard isDirectory(legacyDirectory) else { return .nothingToMigrate }
        guard !itemExists(currentDirectory) else { return .alreadyMigrated }
        guard legacyAppHasQuit() else { return .legacyAppRunning }
        do {
            try fileManager.createDirectory(at: currentDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try move(legacyDirectory, currentDirectory)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Fordert eine laufende alte App zum Beenden auf und wartet höchstens `quitTimeout` darauf.
    private func legacyAppHasQuit() -> Bool {
        guard isLegacyAppRunning() else { return true }
        quitLegacyApp()
        let deadline = ContinuousClock.now.advanced(by: quitTimeout)
        while isLegacyAppRunning() {
            guard ContinuousClock.now < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    /// Übernimmt die in `defaults` noch fehlenden Schlüssel aus `migratedDefaultsKeys`; liefert die übernommenen.
    @discardableResult
    public func migrateDefaults() -> [String] {
        guard let legacyDefaults else { return [] }
        var migrated: [String] = []
        for key in Self.migratedDefaultsKeys where defaults.object(forKey: key) == nil {
            guard let value = legacyDefaults.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            migrated.append(key)
        }
        return migrated
    }

    /// Echter Ordner (kein Symlink, keine Datei).
    private func isDirectory(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// Irgendein Eintrag, auch ein Symlink, dessen Ziel fehlt.
    private func itemExists(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }
}
