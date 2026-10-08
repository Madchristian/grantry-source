import Foundation

/// Warum ein Fund des Aufräumens als Rest galt – die Regeln von `OrphanScanner`, die vor dem Papierkorb gegen den
/// aktuellen Stand erneut geprüft werden (`OrphanRecheck`).
struct OrphanClaim: Hashable, Sendable {
    /// Kennungen, die keiner installierten App oder Komponente gehören durften (`OrphanInventory.owns`): eigene
    /// Kennung und die der Gruppe bzw. bei Herstellerordnern der Ordnername.
    let identifiers: [String]
    /// Team-ID eines Team-Gruppen-Containers; keine installierte App durfte sie tragen.
    var team: String?
    /// Herstellerordner (`Application Support/OpenClaw`): Name, den keine installierte App tragen durfte, und die Kennung
    /// der Gruppe, deren Hersteller keine installierten Apps oder Komponenten haben und deren Bestandteile keinen Namen
    /// einer installierten App tragen durften.
    var vendorFolder: VendorFolder?

    struct VendorFolder: Hashable, Sendable {
        let name: String
        let groupIdentifier: String
    }
}

/// Prüft die Funde einer Aufräumen-Suche unmittelbar vor dem Ausführen gegen den **aktuellen** Snapshot und die App-Bundles,
/// die jetzt auf der Platte liegen (`OrphanInventory`): Gehört eine Kennung inzwischen einer installierten App oder
/// Komponente oder läuft ein verwaistes Autostart-Programm wieder, wird der Eintrag übersprungen (Review I1).
/// Ohne aktuellen Snapshot bzw. ohne belastbares App-Inventar wird jeder geprüfte Eintrag übersprungen.
struct OrphanRecheck {
    static let unavailableReason = "Aktueller Stand der installierten Apps liegt nicht vor – nicht angefasst."
    static let programPresentReason = "Programm ist wieder vorhanden – nicht angefasst."

    static func ownedReason(by owner: String) -> String {
        "Gehört jetzt zu „\(owner)“ – nicht angefasst."
    }

    private enum State {
        case unavailable(String)
        case current(OrphanInventory, Snapshot)
    }

    private let state: State

    init(current snapshot: Snapshot?, layout: LibraryLayout) {
        guard let snapshot else {
            state = .unavailable(Self.unavailableReason)
            return
        }
        let inventory = OrphanInventory(snapshot: snapshot, layout: layout)
        if case .unavailable(let reason) = inventory.coverage {
            state = .unavailable("\(reason) – nicht angefasst.")
        } else {
            state = .current(inventory, snapshot)
        }
    }

    /// Grund zum Überspringen der Datei mit `claim`; `nil`, wenn sie weiterhin als Rest gilt.
    func reason(for claim: OrphanClaim) -> String? {
        switch state {
        case .unavailable(let reason): return reason
        case .current(let inventory, _): return Self.owner(of: claim, in: inventory).map(Self.ownedReason(by:))
        }
    }

    /// Grund zum Überspringen des verwaisten Autostart-Eintrags; `nil`, wenn sein Programm weiterhin fehlt.
    func reason(for item: AutostartItem) -> String? {
        switch state {
        case .unavailable(let reason):
            return reason
        case .current(_, let snapshot):
            let current = snapshot.autostartItems.first { $0.id == item.id }
            return current.map { $0.programPresence != .missing } == true ? Self.programPresentReason : nil
        }
    }

    private static func owner(of claim: OrphanClaim, in inventory: OrphanInventory) -> String? {
        for identifier in claim.identifiers {
            if let owner = inventory.ownerName(of: identifier) { return owner }
        }
        if let team = claim.team, let owner = inventory.appName(withTeam: team) { return owner }
        if let folder = claim.vendorFolder {
            return inventory.appName(named: folder.name)
                ?? inventory.vendorApps(of: folder.groupIdentifier).first
                ?? inventory.vendorComponents(of: folder.groupIdentifier).first
                ?? inventory.appsNamed(in: folder.groupIdentifier).first
        }
        return nil
    }
}
