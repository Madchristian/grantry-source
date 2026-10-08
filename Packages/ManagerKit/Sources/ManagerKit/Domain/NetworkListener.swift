import Foundation

/// Von wo ein Lauscher erreichbar ist, abgeleitet aus seinen gebundenen Adressen; die höchste gilt.
public enum ListenerReachability: Hashable, Sendable, Codable {
    /// Nur Loopback (`127.0.0.0/8`, `::1`, `::ffff:127.x.x.x`).
    case thisMac
    /// Mindestens eine Nicht-Loopback-Adresse oder keine Adresse bekannt; `allInterfaces` bei einer Wildcard
    /// (`0.0.0.0`, `::`, `*`).
    case network(allInterfaces: Bool)

    /// Ohne bekannte Adresse gilt konservativ `.network(allInterfaces: false)`: Ein Sicherheitswerkzeug soll einen
    /// Lauscher nicht als nur lokal einstufen, nur weil seine Adresse fehlt.
    public init(addresses: [String]) {
        if addresses.contains(where: Self.isWildcard) {
            self = .network(allInterfaces: true)
        } else if !addresses.isEmpty, addresses.allSatisfy(Self.isLoopback) {
            self = .thisMac
        } else {
            self = .network(allInterfaces: false)
        }
    }

    /// Von anderen Geräten erreichbar.
    public var isExposed: Bool { self != .thisMac }

    private static func isWildcard(_ address: String) -> Bool {
        ["0.0.0.0", "::", "*", "::ffff:0.0.0.0"].contains(address)
    }

    private static func isLoopback(_ address: String) -> Bool {
        let plain = address.hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address
        return plain == "::1" || plain.hasPrefix("127.")
    }
}

/// Einordnung des Benutzers eines Lauschers relativ zum Benutzer der App.
public enum ListenerUser: Hashable, Sendable {
    case current, root
    case other(uid: UInt32)

    public init(uid: UInt32, currentUID: UInt32) {
        self = uid == currentUID ? .current : uid == 0 ? .root : .other(uid: uid)
    }
}

/// Ports im macOS-Ephemeralbereich (`net.inet.ip.portrange.first` … `last`, Vorgabe 49152–65535): vom System bei
/// `bind(0)` vergeben, wechseln mit jedem Start.
public enum ListenerPort {
    public static let ephemeralRange: ClosedRange<UInt16> = 49152...65535

    public static func isEphemeral(_ port: UInt16) -> Bool { ephemeralRange.contains(port) }

    /// Wechselnder Port: Der Kernel hat ihn vergeben (`ListeningSocket.hasSystemAssignedPort`). Ein ausdrücklich
    /// gewählter Port bleibt fest, auch im Ephemeralbereich (WireGuard auf 51820). Nur ohne das Flag (älterer Helper)
    /// entscheidet der Bereich.
    public static func isVariable(_ socket: ListeningSocket) -> Bool {
        socket.hasSystemAssignedPort ?? isEphemeral(socket.localPort)
    }
}

/// Takt der Lauscher-Erfassung.
public enum ListenerTiming {
    /// Mindestabstand zwischen zwei Helper-Abfragen der Sockets aller Benutzer (`NetworkListenerSource`,
    /// `ListenerHelperSchedule`): Fragte die App den root-Helper bei jedem Teilscan, griffe sein Idle-Exit nie. Die
    /// Frist für Lauscher anderer Benutzer (`Snapshot.foreignListenerGracePeriod`) baut darauf auf.
    public static let helperInterval: TimeInterval = 15 * 60
}

/// Ein Programm, das auf einem Port eingehende Verbindungen annimmt. Sockets desselben Programms, Benutzers,
/// Transports und Ports (IPv4 und IPv6, mehrere Prozesse) bilden einen Eintrag; vom System vergebene Ports gelten als
/// „wechselnd“ (`port == nil`, `ListenerPort.isVariable`), damit ein Neustart mit neuem Zufallsport keinen neuen
/// Eintrag ergibt.
public struct NetworkListener: InventoryRecord, Codable {
    public var executablePath: String
    public var uid: UInt32
    public var transport: SocketTransport
    /// `nil`: wechselnder Port (Ephemeralbereich).
    public var port: UInt16?
    /// Gebundene Adressen, sortiert und eindeutig.
    public var addresses: [String]
    public var signing: SigningInfo
    /// Programmpfade der Elternkette (nächster zuerst), für die Zuordnung zu einer App.
    public var ancestorPaths: [String]
    /// Erster Scan, in dem der Lauscher gesehen wurde (fortgeschrieben).
    public var firstSeenAt: Date
    /// Letzter Scan, in dem er tatsächlich gesehen wurde (Entprellung, `Snapshot.carryingForwardListeners`).
    public var lastSeenAt: Date

    public init(executablePath: String, uid: UInt32, transport: SocketTransport, port: UInt16?, addresses: [String],
                signing: SigningInfo, ancestorPaths: [String] = [], firstSeenAt: Date, lastSeenAt: Date) {
        self.executablePath = executablePath
        self.uid = uid
        self.transport = transport
        self.port = port
        self.addresses = Array(Set(addresses)).sorted()
        self.signing = signing
        self.ancestorPaths = ancestorPaths
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    public var id: String { "\(executablePath)|\(uid)|\(transport.rawValue)|\(port.map(String.init) ?? "wechselnd")" }
    public var source: SourceID { .networkListeners }
    public var reachability: ListenerReachability { ListenerReachability(addresses: addresses) }
    /// Programm samt Signatur – Name, App-Zuordnung und Apple-Einstufung (`NetworkProgram`).
    public var program: NetworkProgram { NetworkProgram(executablePath: executablePath, signing: signing) }
    /// Letzter Pfadbestandteil des Programms (`pbi_name` ist auf 32 Zeichen gekürzt).
    public var processName: String { program.processName }
    /// Interpreter oder Netzwerkwerkzeug (`NetworkProgram.isInstructionDriven`).
    public var isInstructionDriven: Bool { program.isInstructionDriven }
    /// Dienst von macOS (`NetworkProgram.isAppleService`).
    public var isAppleService: Bool { program.isAppleService }

    /// Vermutlich ein Client, kein Dienst: UDP auf wechselndem Port (WebRTC/STUN in Browsern, Discord, Zoom) oder mDNS
    /// (5353) eines regulär signierten Programms (Developer ID, App Store; `.development` zählt nicht). Solche Lauscher
    /// bleiben sichtbar, ergeben aber keinen Befund (`ExposedListenerRule`), keine Meldung (`NotificationPolicy`) und
    /// zählen nicht zu `NetworkOverview.exposedCount` – sonst schlüge „Von außen erreichbar“ bei jedem Browser an.
    ///
    /// „Wechselnd“ heißt vom System vergeben (`ListenerPort.isVariable`); ein ausdrücklich gewählter Port im
    /// Ephemeralbereich (WireGuard auf 51820) bleibt ein Dienst. Grenze: Ohne das Kernel-Flag (älterer Helper) zählt
    /// der Portbereich, und ein fester Port dort ist nicht zu unterscheiden. Unsignierte, ad-hoc-signierte,
    /// Interpreter und Netzwerkwerkzeuge fallen nie darunter.
    public var isBenignClientUDP: Bool {
        transport == .udp && (port == nil || port == 5353) && [.developerID, .appStore].contains(signing.kind)
            && !isInstructionDriven
    }

    /// Von außen erreichbarer Dienst, kein vermutlicher Client (`isBenignClientUDP`); Grundlage des Filters „Von außen
    /// erreichbar“, der Dienste von macOS nur zusammen mit „Systemdienste anzeigen“ zeigt.
    public var isExposedService: Bool { reachability.isExposed && !isBenignClientUDP }

    /// Zählt zur Kachel „Von außen erreichbar“ (`NetworkOverview.exposedCount`): erreichbarer Dienst, der nicht von
    /// macOS stammt. Bei ausgeblendeten Systemdiensten zeigt der Filter „Von außen erreichbar“ genau diese Lauscher.
    public var countsAsExposed: Bool { isExposedService && !isAppleService }

    /// Erreichbarkeit oder bekannte Signatur (Art, Team-ID) geändert; `.unknown` zählt nicht (Zeitüberschreitung).
    public func hasSignificantChanges(comparedTo other: NetworkListener) -> Bool {
        reachability != other.reachability
            || (signing.kind != .unknown && other.signing.kind != .unknown
                && (signing.kind != other.signing.kind || signing.teamID != other.signing.teamID))
    }

    /// Im Verlauf zählt nur ein Wechsel der Erreichbarkeit.
    public func reportsChange(to other: NetworkListener) -> Bool { reachability != other.reachability }
}
