/// Die absichernden Operationen des Helpers (Spec v2 §3) mit ihren **festen** Kommandozeilen. Nur Richtung
/// „sicherer“: Es gibt bewusst keinen Fall und kein Argument zum Abschalten (geprüft in `SecurityHardeningTests`).
public enum SecurityHardening: String, CaseIterable, Sendable {
    case enableFirewall, enableStealthMode, enableGatekeeper, enableAutomaticUpdates, updateXProtect

    /// Ein fester Befehlsaufruf mit absolutem Pfad.
    public struct Invocation: Hashable, Sendable {
        public let executable: String
        public let arguments: [String]

        /// Befehl samt Argumenten, durch Leerzeichen getrennt (Protokoll, Fehlermeldung, Tests).
        public var commandLine: String { ([executable] + arguments).joined(separator: " ") }
    }

    /// Lesender Befehl, den der Helper **vor** dem Setzen ausführt: Ist das Ziel schon erreicht, setzt er nichts.
    ///
    /// Wichtig für die Firewall: `--setglobalstate on` bei aktivem „Alle eingehenden blockieren“ könnte auf den
    /// schwächeren Zustand „an“ zurücksetzen. Gesetzt wird darum nur, wenn sie aus ist. Gatekeeper folgt demselben
    /// Muster: `spctl --global-enable` nur, wenn `spctl --status` „assessments disabled“ meldet.
    ///
    /// Ausgewertet wird stdout unabhängig vom Exit-Code: `spctl --status` endet bei „assessments disabled“ mit Exit 1.
    /// Erst eine unbekannte Ausgabe macht einen Exit ≠ 0 zum Fehler.
    public struct StateQuery: Sendable {
        public let invocation: Invocation
        private let interpret: @Sendable (_ output: String) -> Bool?

        init(_ invocation: Invocation, interpret: @escaping @Sendable (_ output: String) -> Bool?) {
            self.invocation = invocation
            self.interpret = interpret
        }

        /// `true`: Ziel erreicht (oder strenger) – nichts setzen. `false`: setzen. `nil`: Ausgabe unbekannt – abbrechen
        /// statt blind zu setzen.
        public func isTargetReached(in output: String) -> Bool? {
            interpret(output)
        }
    }

    /// Vorab-Abfrage des Zustands; `nil`, wenn erneutes Setzen nie abschwächen kann.
    public var stateQuery: StateQuery? {
        switch self {
        case .enableFirewall:
            // Ausgewertet wird wie in der App (`SocketFilterFirewallOutput`): Nur `State = 0` ist aus; `1` (an) und `2`
            // (alle eingehenden blockieren) bleiben unberührt – auch bei getrennt gemeldetem „alle blockieren“.
            StateQuery(
                Invocation(executable: SecurityTools.socketfilterfw, arguments: ["--getglobalstate"]),
                interpret: SocketFilterFirewallOutput.isEnabled(in:)
            )
        case .enableStealthMode:
            StateQuery(
                Invocation(executable: SecurityTools.socketfilterfw, arguments: ["--getstealthmode"]),
                interpret: SocketFilterFirewallOutput.isStealthModeOn(in:)
            )
        case .enableGatekeeper:
            // Ausgewertet wie in der App (`GatekeeperStatusOutput`).
            StateQuery(
                Invocation(executable: SecurityTools.spctl, arguments: ["--status"]),
                interpret: GatekeeperStatusOutput.isEnabled(in:)
            )
        case .enableAutomaticUpdates, .updateXProtect:
            nil
        }
    }

    /// Nacheinander auszuführende Befehle; der erste Fehler bricht ab.
    public var invocations: [Invocation] {
        switch self {
        case .enableFirewall:
            [Invocation(executable: SecurityTools.socketfilterfw, arguments: ["--setglobalstate", "on"])]
        case .enableStealthMode:
            [Invocation(executable: SecurityTools.socketfilterfw, arguments: ["--setstealthmode", "on"])]
        case .enableGatekeeper:
            [Invocation(executable: SecurityTools.spctl, arguments: ["--global-enable"])]
        case .enableAutomaticUpdates:
            SoftwareUpdateKey.allCases.map { key in
                Invocation(
                    executable: SecurityTools.defaults,
                    arguments: ["write", SecurityTools.softwareUpdateDefaultsDomain, key.rawValue, "-bool", "true"]
                )
            }
        case .updateXProtect:
            [Invocation(executable: SecurityTools.xprotect, arguments: ["update"])]
        }
    }

    /// Frist je Befehl; `xprotect update` lädt ggf. aus dem Netz.
    public var timeout: Duration {
        self == .updateXProtect ? .seconds(120) : .seconds(30)
    }

    /// Zahl der Befehle im Helper, Zustandsabfrage eingeschlossen.
    public var commandCount: Int { invocations.count + (stateQuery == nil ? 0 : 1) }

    /// Längste Laufzeit im Helper (ohne Wartezeit in seiner Warteschlange): Jeder Befehl schöpft `timeout` und die
    /// Gnadenfrist des `ProcessCommandRunner` aus.
    public var maximumDuration: Duration {
        (timeout + ProcessCommandRunner.defaultTerminationGracePeriod) * commandCount
    }
}
