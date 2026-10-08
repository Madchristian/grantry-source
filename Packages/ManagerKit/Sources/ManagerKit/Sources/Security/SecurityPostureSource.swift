import Foundation

/// Quelle des Sicherheitsstatus (Spec v2 §3): je Prüfung ein `SecurityProbe`, parallel ausgeführt. Scheitert eine
/// Probe, wird nur ihre Prüfung `unknown` (mit Fehlertext); die Quelle selbst scheitert nie an einer Probe. Jede
/// Prüfung `unknown` ist dafür eine Einschränkung mit Name und Grund (#142) – der Bereich gilt dann nicht als
/// vollständig geprüft.
public struct SecurityPostureSource: InventorySource {
    public let id = SourceID.securityPosture

    /// Dateien, deren Änderung (auch: Erscheinen) einen Scan auslösen soll. Unter macOS 27 liegt der Firewall-Zustand
    /// in `com.apple.networkextension.plist`; die Datei kann beim Start fehlen.
    public static let watchedFiles = [
        SecurityTools.softwareUpdatePreferences,
        SecurityTools.networkExtensionPreferences,
    ]

    /// Ordner, deren Änderung einen Scan auslösen soll: das aktuelle XProtect unter `/var/protected/xprotect` und das
    /// der OS-Installation.
    public static let watchedDirectories = [
        SecurityTools.xprotectBundle,
        SecurityTools.systemXProtectBundle,
    ]

    private let probes: [any SecurityProbe]
    private let policy: SecurityPolicy
    private let now: @Sendable () -> Date

    public init(probes: [any SecurityProbe], policy: SecurityPolicy = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.probes = probes
        self.policy = policy
        self.now = now
    }

    /// Die acht Prüfungen aus Spec §2.
    public static func standard(
        runner: any CommandRunning = ProcessCommandRunner(),
        readPreferences: @escaping @Sendable () throws -> Data = {
            try Data(contentsOf: URL(filePath: SecurityTools.softwareUpdatePreferences))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) -> SecurityPostureSource {
        func command(
            _ kind: SecurityCheckKind, _ executable: String, _ arguments: [String],
            _ parse: @escaping @Sendable (String) throws -> SecurityFacts
        ) -> any SecurityProbe {
            CommandSecurityProbe(kind: kind, executable: executable, arguments: arguments, parse: parse, runner: runner)
        }
        return SecurityPostureSource(probes: [
            command(.fileVault, SecurityTools.fdesetup, ["status"], SecurityParsers.fileVault),
            command(.firewall, SecurityTools.socketfilterfw, ["--getglobalstate", "--getstealthmode"], SecurityParsers.firewall),
            command(.sip, SecurityTools.csrutil, ["status"], SecurityParsers.sip),
            command(.gatekeeper, SecurityTools.spctl, ["--status"], SecurityParsers.gatekeeper),
            command(.xprotect, SecurityTools.xprotect, ["version", "--json"], SecurityParsers.xprotect),
            SoftwareUpdateProbe(readPreferences: readPreferences),
            command(.mdmEnrollment, SecurityTools.profiles, ["status", "-type", "enrollment"], SecurityParsers.mdmEnrollment),
        ], now: now)
    }

    /// Prüfungen in Anzeigereihenfolge (`SecurityCheckKind.allCases`).
    public func collect() async throws -> InventoryContribution {
        let now = now()
        let checks = await withTaskGroup(of: [SecurityCheck].self) { [policy] group in
            for probe in probes {
                group.addTask { await Self.checks(of: probe, policy: policy, now: now) }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        let rank = Dictionary(uniqueKeysWithValues: SecurityCheckKind.allCases.enumerated().map { ($1, $0) })
        let sorted = checks.sorted { rank[$0.kind, default: .max] < rank[$1.kind, default: .max] }
        return InventoryContribution(securityChecks: sorted, retryableLimitations: Self.limitations(of: sorted))
    }

    /// „Systemintegritätsschutz (SIP) nicht geprüft: Zeitüberschreitung …“ je Prüfung `unknown` – der nächste Scan
    /// fragt die Probe erneut.
    static func limitations(of checks: [SecurityCheck]) -> [String] {
        checks.filter { $0.state == .unknown }.map { check in
            "\(check.kind.displayName) nicht geprüft: \(check.detail ?? "Ergebnis nicht auswertbar")"
        }
    }

    /// Bewertete Prüfungen der Probe oder – bei einem Fehler – ihre Prüfungen `unknown` mit Fehlertext.
    private static func checks(of probe: any SecurityProbe, policy: SecurityPolicy, now: Date) async -> [SecurityCheck] {
        do {
            return try await probe.read(now: now).map { facts in
                SecurityCheck(kind: facts.kind, state: policy.evaluate(facts, now: now), facts: facts)
            }
        } catch {
            return probe.kinds.map { .failed($0, detail: error.readableDescription) }
        }
    }
}
