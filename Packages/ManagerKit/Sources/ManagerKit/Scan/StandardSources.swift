import Foundation

/// Zusammenstellung der Datenquellen je Produktversion.
public enum StandardSources {
    /// v1: System-TCC, launchd, BTM (über den Helper). Die Benutzer-TCC.db wird nicht gescannt (Nutzerentscheidung;
    /// unter macOS 27 ohnehin nicht lesbar).
    ///
    /// - Parameter fingerprinter: Schlüssel der Fingerabdrücke maskierter launchd-Argumente; dauerhaft, damit Scans
    ///   über Neustarts hinweg vergleichbar bleiben (`StorageLocation.secretFingerprinter()`).
    public static func v1(
        btmProvider: any BTMDumpProviding,
        resolver: any AppResolving,
        fingerprinter: SecretFingerprinter,
        runner: any CommandRunning = ProcessCommandRunner()
    ) -> [any InventorySource] {
        TCCSource.standard(resolver: resolver)
            + [LaunchdSource(runner: runner, resolver: resolver, fingerprinter: fingerprinter),
               BTMSource(provider: btmProvider, resolver: resolver)]
    }

    /// v2: v1 plus Sicherheitsstatus.
    ///
    /// - Parameter now: Uhr der Sicherheitsbewertung; dieselbe wie die des `ScanCoordinator`, der die Ampel nach dem
    ///   Fortschreiben zu seinem `startedAt` neu bewertet.
    public static func v2(
        btmProvider: any BTMDumpProviding,
        resolver: any AppResolving,
        fingerprinter: SecretFingerprinter,
        runner: any CommandRunning = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) -> [any InventorySource] {
        v1(btmProvider: btmProvider, resolver: resolver, fingerprinter: fingerprinter, runner: runner)
            + [SecurityPostureSource.standard(runner: runner, now: now)]
    }

    /// v3: v2 plus App-Inventar.
    public static func v3(
        btmProvider: any BTMDumpProviding,
        resolver: any AppResolving,
        fingerprinter: SecretFingerprinter,
        runner: any CommandRunning = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init,
        apps: AppInventorySource = AppInventorySource()
    ) -> [any InventorySource] {
        v2(btmProvider: btmProvider, resolver: resolver, fingerprinter: fingerprinter, runner: runner, now: now) + [apps]
    }

    /// v4: v3 plus Agenten-Konfigurationen (#129).
    public static func v4(
        btmProvider: any BTMDumpProviding,
        resolver: any AppResolving,
        fingerprinter: SecretFingerprinter,
        runner: any CommandRunning = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init,
        apps: AppInventorySource = AppInventorySource(),
        agents: AgentConfigSource? = nil
    ) -> [any InventorySource] {
        v3(btmProvider: btmProvider, resolver: resolver, fingerprinter: fingerprinter, runner: runner, now: now, apps: apps)
            + [agents ?? AgentConfigSource(fingerprinter: fingerprinter)]
    }

    /// v5: v4 plus lauschende Netzwerkdienste (#128).
    ///
    /// - Parameters:
    ///   - sockets: Helper-Zugang für Sockets aller Benutzer; `nil` ohne eingerichteten Helper.
    ///   - listenerSchedule: Takt der Helper-Abfragen; die App setzt ihn nach einer Helper-Registrierung zurück.
    ///   - listenerTerminations: von „Prozess beenden …“ vermerkte Lauscher; App und `ProcessTerminator` teilen ihn.
    public static func v5(
        btmProvider: any BTMDumpProviding,
        resolver: any AppResolving,
        sockets: (any ListeningSocketProviding)?,
        fingerprinter: SecretFingerprinter,
        runner: any CommandRunning = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init,
        apps: AppInventorySource = AppInventorySource(),
        agents: AgentConfigSource? = nil,
        listenerSchedule: ListenerHelperSchedule = ListenerHelperSchedule(),
        listenerTerminations: ListenerTerminationLedger = ListenerTerminationLedger()
    ) -> [any InventorySource] {
        v4(btmProvider: btmProvider, resolver: resolver, fingerprinter: fingerprinter, runner: runner, now: now, apps: apps,
           agents: agents)
            + [NetworkListenerSource(
                provider: sockets, now: now, schedule: listenerSchedule, terminations: listenerTerminations
            )]
    }
}
