import Darwin
import GrantryShared

extension ActionPolicy {
    /// Ob Grantry den Dienst eines Autostart-Eintrags starten und stoppen darf (Tab „Dienste“, Spec 2026-11-06 §6): nur
    /// eigene LaunchAgents aus `~/Library/LaunchAgents`, die `availability(for:)` nicht sperrt (keine Apple-Komponenten,
    /// keine anderen Sitzungstypen, nur aktuell gelesene Plists). Agenten aus `/Library/LaunchAgents` und System-Dienste
    /// bleiben bis zum Helper (TM9) Anzeige.
    ///
    /// Zusätzlich gilt die Schutzliste von „Task beenden“ (`ProtectedProcesses.system`): Ein eigener Agent, dessen
    /// Programm dort steht, wird nie freigegeben – `availability(for:)` prüft nur Label, Eigentümer und Signatur, ein
    /// Agent mit fremdem Label könnte sonst `launchd` oder `loginwindow` starten. Die Prüfung steht vor
    /// `availability(for:)`, damit der Grund die Schutzliste nennt. Liegt das Programm nicht sicher lokal (Netzlaufwerk,
    /// Symlink dorthin), bleibt die Steuerung gesperrt, ohne den Pfad aufzulösen (`unverifiableProgram`).
    public func serviceControlAvailability(for item: AutostartItem) -> ActionAvailability {
        serviceControlAvailability(for: item, volumes: MountedVolume.current())
    }

    /// Wie `serviceControlAvailability(for:)`, mit den Einhängepunkten, die der Aufrufer einmal für mehrere Einträge liest.
    func serviceControlAvailability(for item: AutostartItem, volumes: [MountedVolume]) -> ActionAvailability {
        guard item.kind == .launchAgent, item.domain == .user else { return .readOnly(.notOwnAgent) }
        if let program = item.program {
            switch ProtectedProcesses.system.check(serviceProgram: program, volumes: volumes) {
            case .protected: return .readOnly(.protectedProgram)
            case .unverifiable: return .readOnly(.unverifiableProgram)
            case .unprotected: break
            }
        }
        return availability(for: item)
    }
}

extension ProtectedProcesses {
    /// Ergebnis der Schutzlistenprüfung eines Programmpfads.
    enum ProtectionCheck: Equatable {
        case protected, unprotected
        /// Der Pfad liegt nicht sicher lokal: Ihn zu kanonisieren (`FilePath.canonical`) griffe auf das Dateisystem zu,
        /// auch auf ein hängendes Netzlaufwerk.
        case unverifiable
    }

    /// Ob ein Dienst mit diesem Programm (`AutostartItem.program`) auf der Liste steht. Ein Dienst ohne laufenden
    /// Prozess hat keine PID, deshalb zählt nur der Pfad; ohne Verzeichnis sucht launchd das Programm im Standard-PATH
    /// (`LaunchdSearchPath`, ein eigener `PATH` der Plist bleibt unberücksichtigt). Ein relativer Pfad mit Verzeichnis
    /// hängt am Arbeitsverzeichnis des Dienstes und kann über `..` auf ein Netzlaufwerk zeigen: `.unverifiable`, bevor
    /// irgendetwas das Dateisystem fragt.
    func check(serviceProgram program: String, volumes: [MountedVolume]) -> ProtectionCheck {
        if !program.hasPrefix("/"), program.contains("/") { return .unverifiable }
        let path = program.hasPrefix("/") ? program : LaunchdSearchPath.executable(named: program)
        // `pid_t.max` ist keine reservierte PID (0 und 1 schützt `check(pid:executablePath:volumes:)` immer).
        return path.map { check(pid: .max, executablePath: $0, volumes: volumes) } ?? .unprotected
    }

    /// Wie `protects(pid:executablePath:)`, aber erst nachdem `LocalPathResolver` den Pfad Komponente für Komponente
    /// anhand der Einhängepunkte als sicher lokal bestätigt hat; verglichen wird der aufgelöste Pfad. Ein unlesbarer
    /// Pfad (`""`) schützt nichts.
    func check(pid: pid_t, executablePath: String, volumes: [MountedVolume]) -> ProtectionCheck {
        if pid <= 1 { return .protected }
        guard !executablePath.isEmpty else { return .unprotected }
        guard let target = LocalPathResolver.resolve(executablePath, volumes: volumes) else { return .unverifiable }
        return protects(pid: pid, executablePath: target.path) ? .protected : .unprotected
    }
}
