import Foundation

extension NetworkListener {
    /// „3000/tcp“, „wechselnd/tcp“.
    public var portText: String { "\(port.map(String.init) ?? "wechselnd")/\(transport.rawValue)" }

    /// „Port 3000/tcp“, „wechselnder Port, tcp“ – für Fließtext, ohne eigene Klammern.
    public var portLabel: String {
        port.map { "Port \($0)/\(transport.rawValue)" } ?? "wechselnder Port, \(transport.rawValue)"
    }

    /// „alle Schnittstellen“, „Netzwerk, 192.168.1.5“, „nur dieser Mac“; ohne bekannte Adresse nur „Netzwerk“.
    public var reachabilityText: String {
        switch reachability {
        case .thisMac: "nur dieser Mac"
        case .network(allInterfaces: true): "alle Schnittstellen"
        case .network(allInterfaces: false):
            (["Netzwerk"] + addresses.filter { ListenerReachability(addresses: [$0]).isExposed }).joined(separator: ", ")
        }
    }

    /// „auf Port 3000/tcp“ bzw. „auf einem wechselnden Port“ (ohne Transport, siehe `ChangeDescription`).
    var portPhrase: String {
        port == nil ? "auf einem wechselnden Port" : "auf \(portLabel)"
    }
}

extension ListenerUser {
    public var displayName: String {
        switch self {
        case .current: "Eigener Benutzer"
        case .root: "System (root)"
        case .other(let uid): "Anderer Benutzer (\(uid))"
        }
    }
}

// MARK: - Änderungstexte

extension ChangeDescription {
    /// Texte zu neuen, in der Erreichbarkeit geänderten und beendeten Lauschern (`ChangeDescription.init(_:)`).
    static func describe(_ kind: ChangeEvent.Kind, listener: NetworkListener, previous: NetworkListener?) -> Self {
        let name = listener.processName
        switch kind {
        case .added:
            let location = listener.port == nil
                ? "\(listener.portPhrase) (\(listener.transport.rawValue), \(listener.reachabilityText))"
                : "\(listener.portPhrase) (\(listener.reachabilityText))"
            return Self(title: "Neuer Netzwerkdienst", body: "\(name) lauscht \(location).")
        case .modified:
            let before = previous?.reachabilityText ?? "unbekannt"
            return Self(title: modifiedTitle(from: previous?.reachability, to: listener.reachability),
                        body: "\(name), \(listener.portLabel): \(before) → \(listener.reachabilityText).")
        case .removed:
            return Self(title: "Netzwerkdienst beendet", body: "\(name), \(listener.portLabel).")
        }
    }

    /// „jetzt von außen erreichbar“ nur beim Wechsel von „nur dieser Mac“ ins Netz.
    private static func modifiedTitle(from before: ListenerReachability?, to after: ListenerReachability) -> String {
        if after == .thisMac { return "Netzwerkdienst nur noch lokal erreichbar" }
        if before == .thisMac { return "Netzwerkdienst jetzt von außen erreichbar" }
        return "Netzwerkdienst: Erreichbarkeit geändert"
    }
}
