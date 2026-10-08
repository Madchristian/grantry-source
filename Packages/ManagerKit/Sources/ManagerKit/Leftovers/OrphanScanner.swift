import Foundation

/// Reste einer gelöschten App, gruppiert unter der kürzesten Kennung.
public struct OrphanGroup: Identifiable, Hashable, Sendable {
    public let identifier: String
    public let candidates: [LeftoverCandidate]
    /// Je Kandidaten-Pfad, warum er als Rest galt – vor dem Papierkorb erneut geprüft (`OrphanRecheck`).
    let claims: [String: OrphanClaim]
    public var id: String { identifier }

    init(identifier: String, candidates: [LeftoverCandidate], claims: [String: OrphanClaim] = [:]) {
        self.identifier = identifier
        self.candidates = candidates
        self.claims = claims
    }
}

/// Stand der installierten Apps, gegen den gesucht wurde (Pfad und Bundle-ID je App).
public struct InstalledAppsStamp: Hashable, Sendable {
    private struct Entry: Hashable, Sendable {
        let path: String
        let bundleID: String?
    }

    private let entries: Set<Entry>

    public init(_ apps: [InstalledApp]) {
        entries = Set(apps.map { Entry(path: $0.path, bundleID: $0.bundleID) })
    }
}

/// Wie belastbar der Abgleich mit den installierten Apps war.
public enum OrphanScanCoverage: Hashable, Sendable {
    /// Alle App-Ordner gelesen, jede gefundene App mit Bundle-ID.
    case complete
    /// Teile fehlen (Ordner nicht lesbar, Apps ohne bekannte Bundle-ID): Jeder Fund ist unsicher und nicht vorausgewählt.
    case incomplete(String)
    /// Ohne App-Inventar bzw. lesbare App-Wurzel ist kein Fund belegt – es gibt keine Gruppen.
    case unavailable(String)
}

/// Ergebnis von „Reste gelöschter Apps suchen“ (Spec v3 §3 „Aufräumen“).
public struct OrphanScanResult: Hashable, Sendable {
    public let groups: [OrphanGroup]
    /// Autostart-Einträge, deren Programm nachweislich fehlt und die sich mit der v1-Aktion entfernen lassen.
    public let autostartItems: [AutostartItem]
    /// Berechtigungen entfernter Apps – nur Hinweis: `tccutil` braucht die installierte App.
    public let grants: [PermissionGrant]
    /// Reste-Orte, die sich nicht lesen ließen – dort ist „keine Reste“ nicht belegt.
    public let unreadableLocations: [String]
    public let coverage: OrphanScanCoverage
    /// Installierte Apps des Snapshots, gegen den gesucht wurde.
    public let installedApps: InstalledAppsStamp

    public init(
        groups: [OrphanGroup], autostartItems: [AutostartItem], grants: [PermissionGrant],
        unreadableLocations: [String] = [], coverage: OrphanScanCoverage = .complete,
        installedApps: InstalledAppsStamp = InstalledAppsStamp([])
    ) {
        self.groups = groups
        self.autostartItems = autostartItems
        self.grants = grants
        self.unreadableLocations = unreadableLocations
        self.coverage = coverage
        self.installedApps = installedApps
    }

    /// Die installierten Apps in `snapshot` weichen vom Stand der Suche ab – das Ergebnis ist veraltet.
    public func isOutdated(comparedTo snapshot: Snapshot) -> Bool {
        InstalledAppsStamp(snapshot.installedApps) != installedApps
    }

    /// Warum jeder Fund als Rest galt, je Pfad.
    var claims: [String: OrphanClaim] {
        Dictionary(groups.flatMap(\.claims)) { first, _ in first }
    }

    public static let empty = OrphanScanResult(groups: [], autostartItems: [], grants: [])

    /// Alle Funde als Reste-Ergebnis – jeder mit `identity`, vor dem Papierkorb zu prüfen mit
    /// `RemovalGuard.check(_:allowingAppleIDOf: nil)`.
    public var leftovers: LeftoverScanResult {
        LeftoverScanResult(candidates: groups.flatMap(\.candidates), unreadableLocations: unreadableLocations)
    }
}

/// Sucht Reste gelöschter Apps an den Reste-Orten (Plan-Abweichung 8, nur auf Abruf).
///
/// Ein Eintrag zählt nur, wenn
/// - sein Name wie eine Bundle-ID aussieht (`BundleIDShape.isPlausible`) und keine Apple-Kennung ist – auch nicht mit
///   Freigabe (`BundleIDShape.isApple`, zusätzlich der `RemovalGuard` ohne Apple-Freigabe);
/// - keine installierte App ihn besitzt und er nicht der Namensraum einer installierten App ist. Abgeglichen wird mit dem
///   Snapshot **und** den App-Bundles, die gerade auf der Platte liegen (auch versteckte, zweite Kopien, neue seit dem
///   letzten Scan; `OrphanInventory`);
/// - der `RemovalGuard` ihn zulässt (keine Symlinks, Sperr- und Einhängepunkte) – vor jeder Anfrage an Systemdienste;
/// - Launch Services **und** Spotlight die Kennung seiner Gruppe und seine eigene nicht kennen
///   (`Presence.probablyMissing`/`.missing`). Gefragt wird nur mit der Kennung (geprüfte ASCII-Zeichenkette) über
///   `AppResolving` – mit dessen Frist und Cache –, je Kennung höchstens einmal; nie mit einem Pfad.
///
/// Sicher (vorausgewählt) ist ein Fund nur ohne jeden Zweifel; unsicher mit Hinweis, wenn er unter `/Library` liegt
/// (`systemWideNote`), der Hersteller installierte Apps oder Komponenten ohne App hat (`OrphanInventory`), die Kennung den Namen einer installierten App enthält, zu einer eingebetteten Bibliothek gehört
/// (`BundleIDShape.isSharedLibrary`), eine verwandte Kennung nicht als entfernt bestätigt ist, ein Team-Container ohne prüfbare Team-IDs aller Apps vorliegt oder das Inventar unvollständig ist. Ohne
/// App-Inventar gibt es keine Gruppen (`OrphanScanCoverage`).
public struct OrphanScanner: Sendable {
    /// Hinweis an jedem Fund unter `/Library` (Review M1): Dort liegen auch Daten von Diensten, Treibern und
    /// Werkzeugen ohne App, die sich nicht vollständig erfassen lassen.
    static let systemWideNote = "Systemweiter Ort – kann zu einer Komponente ohne App gehören"
    /// Hinweis an Containern und Gruppen-Containern (Review N1, Regel siehe `notes(for:inventory:)`).
    static let appDataNote = "Enthält App-Daten – die App könnte auf einem nicht angeschlossenen Laufwerk liegen"
    private let layout: LibraryLayout
    private let resolver: any AppResolving
    private let sizes: any FileSizeMeasuring
    private let removalGuard: RemovalGuard

    public init(
        layout: LibraryLayout = .standard, resolver: any AppResolving,
        sizes: any FileSizeMeasuring = FileSizeCalculator(timeout: FileSizeCalculator.leftoverTimeout)
    ) {
        self.layout = layout
        self.resolver = resolver
        self.sizes = sizes
        removalGuard = RemovalGuard(layout: layout)
    }

    /// Läuft nie auf dem Main Actor. Nach einem Abbruch endet die Suche ohne weitere Anfragen und Messungen.
    @concurrent
    public func scan(_ snapshot: Snapshot) async -> OrphanScanResult {
        let inventory = OrphanInventory(snapshot: snapshot, layout: layout)
        let collection = collectEntries(inventory: inventory)
        var groups: [OrphanGroup] = []
        if inventory.coverage.allowsCandidates {
            var presences = PresenceCache(resolver: resolver)
            var usedVendorFolders = Set<String>()
            for bucket in Self.buckets(collection.entries) {
                guard !Task.isCancelled else { break }
                guard let group = await assess(bucket, inventory: inventory, presences: &presences,
                                               usedVendorFolders: &usedVendorFolders) else { continue }
                groups.append(group)
            }
        }
        let measured = await LeftoverScanner.measured(groups.flatMap(\.candidates)) { _ in sizes }
        let sizesByPath = Dictionary(measured.map { ($0.path, $0.size) }) { first, _ in first }
        groups = groups.map { group in
            OrphanGroup(identifier: group.identifier, candidates: group.candidates.map { candidate in
                var candidate = candidate
                candidate.size = sizesByPath[candidate.path] ?? .unknown
                return candidate
            }, claims: group.claims)
        }
        return OrphanScanResult(
            groups: groups, autostartItems: Self.orphanAutostartItems(in: snapshot), grants: Self.orphanGrants(in: snapshot),
            unreadableLocations: collection.unreadableLocations, coverage: inventory.coverage,
            installedApps: InstalledAppsStamp(snapshot.installedApps)
        )
    }

    // MARK: Autostart und Berechtigungen

    /// Programm fehlt nachweislich, Eintrag mit der v1-Aktion entfernbar (keine Apple-, BTM- oder Login-Items).
    static func orphanAutostartItems(in snapshot: Snapshot) -> [AutostartItem] {
        let policy = ActionPolicy()
        return snapshot.autostartItems
            .filter { $0.programPresence == .missing && policy.availability(for: $0) == .available }
            .sorted { $0.label < $1.label }
    }

    /// Berechtigungen entfernter Apps (ohne Apple-Komponenten).
    static func orphanGrants(in snapshot: Snapshot) -> [PermissionGrant] {
        snapshot.grants
            .filter(\.isOrphaned)
            .sorted { $0.id < $1.id }
    }

    // MARK: Einträge

    /// Ein Eintrag an einem Reste-Ort (Struct statt Tupel, Leitplanke 2).
    struct Entry: Sendable {
        let path: String
        let identifier: String
        let kind: LeftoverKind
        /// Team-ID eines Team-Gruppen-Containers (`<TEAM>.…`).
        let team: String?
        let identity: FileIdentity
        /// Unter `/Library` (`LibraryLayout.isSystemWide`): nie vorausgewählt.
        let isSystemWide: Bool
    }

    struct Bucket {
        let identifier: String
        var entries: [Entry]
    }

    /// Einträge aller Reste-Orte und nicht lesbare Orte (Struct statt Tupel).
    private struct EntryCollection {
        var entries: [Entry] = []
        var unreadableLocations: [String] = []
    }

    private func collectEntries(inventory: OrphanInventory) -> EntryCollection {
        var collection = EntryCollection()
        for location in layout.leftoverLocations {
            guard let names = LeftoverScanner.entries(in: location.directory) else {
                collection.unreadableLocations.append(location.directory)
                continue
            }
            for name in names {
                guard let entry = entry(named: name, in: location, inventory: inventory) else { continue }
                collection.entries.append(entry)
            }
        }
        return collection
    }

    private func entry(named name: String, in location: LeftoverLocation, inventory: OrphanInventory) -> Entry? {
        guard let parsed = Self.identifier(of: name, in: location), BundleIDShape.isPlausible(parsed.identifier),
              !BundleIDShape.isApple(name), !BundleIDShape.isApple(parsed.identifier),
              !inventory.owns(parsed.identifier), parsed.team.map(inventory.teams.contains) != true
        else { return nil }
        let path = location.directory + "/" + name
        guard case .allowed(let identity) = removalGuard.inspect(path, appleOwnerID: nil) else { return nil }
        return Entry(path: path, identifier: parsed.identifier, kind: location.kind, team: parsed.team, identity: identity,
                     isSystemWide: layout.isSystemWide(location))
    }

    /// Kennung und ggf. Team-ID im Eintragsnamen (Struct statt Tupel).
    struct ParsedName: Equatable {
        let identifier: String
        let team: String?
    }

    /// Kennung im Namen; `group.`- und `<TEAM>.`-Präfixe (auch beide) fallen weg – an allen Orten, denn auch
    /// `Application Scripts` enthält Gruppen-Kennungen. In `Group Containers` zählen nur solche Namen.
    static func identifier(of name: String, in location: LeftoverLocation) -> ParsedName? {
        guard let base = location.naming.identifier(in: name) else { return nil }
        switch GroupContainerName(base) {
        case .group(let rest)?:
            return ParsedName(identifier: rest, team: nil)
        case .team(let team, let rest)?:
            let identifier = if case .group(let inner)? = GroupContainerName(rest) { inner } else { rest }
            return ParsedName(identifier: identifier, team: team)
        case nil:
            return location.naming == .groupContainer ? nil : ParsedName(identifier: base, team: nil)
        }
    }

    /// Gruppen unter der kürzesten Kennung, deren `<kennung>.`-Präfix die übrigen tragen (ohne Groß-/Kleinschreibung);
    /// nach Kennung sortiert.
    static func buckets(_ entries: [Entry]) -> [Bucket] {
        var buckets: [Bucket] = []
        for entry in entries.sorted(by: { $0.identifier.count < $1.identifier.count }) {
            let lowered = entry.identifier.lowercased()
            if let index = buckets.firstIndex(where: {
                let key = $0.identifier.lowercased()
                return lowered == key || lowered.hasPrefix(key + ".")
            }) {
                buckets[index].entries.append(entry)
            } else {
                buckets.append(Bucket(identifier: entry.identifier, entries: [entry]))
            }
        }
        return buckets.sorted { $0.identifier.lowercased() < $1.identifier.lowercased() }
    }

    // MARK: Bewertung

    /// Gruppe aus `bucket`, wenn Launch Services und Spotlight die Kennung nicht kennen; Einträge, deren eigene Kennung
    /// nicht als entfernt bestätigt ist, fallen weg (die übrigen werden unsicher).
    private func assess(
        _ bucket: Bucket, inventory: OrphanInventory, presences: inout PresenceCache, usedVendorFolders: inout Set<String>
    ) async -> OrphanGroup? {
        guard await presences.isGone(bucket.identifier) else { return nil }
        var confirmed: [Entry] = [], unconfirmed: Set<String> = []
        for entry in bucket.entries {
            if await presences.isGone(entry.identifier) {
                confirmed.append(entry)
            } else {
                unconfirmed.insert(entry.identifier)
            }
        }
        guard !confirmed.isEmpty else { return nil }

        var notes: [String] = []
        if let reason = inventory.coverage.uncertaintyReason { notes.append(reason) }
        if BundleIDShape.isSharedLibrary(bucket.identifier) {
            notes.append("Kennung einer Bibliothek – gehört evtl. zu einer installierten App")
        }
        let vendorApps = inventory.vendorApps(of: bucket.identifier)
        if !vendorApps.isEmpty { notes.append("Hersteller hat installierte Apps: \(vendorApps.joined(separator: ", "))") }
        let vendorComponents = inventory.vendorComponents(of: bucket.identifier)
        if !vendorComponents.isEmpty {
            notes.append("Hersteller hat installierte Komponenten: \(vendorComponents.joined(separator: ", "))")
        }
        let similarApps = inventory.appsNamed(in: bucket.identifier).filter { !vendorApps.contains($0) }
        if !similarApps.isEmpty { notes.append("Name ähnelt installierter App: \(similarApps.joined(separator: ", "))") }
        if !unconfirmed.isEmpty {
            notes.append("Verwandte Kennung nicht als entfernt bestätigt: \(unconfirmed.sorted().joined(separator: ", "))")
        }

        var claims = Dictionary(confirmed.map { entry in
            (entry.path, OrphanClaim(identifiers: Array(Set([entry.identifier, bucket.identifier])).sorted(), team: entry.team))
        }) { first, _ in first }
        var candidates = confirmed.map { entry in
            let entryNotes = notes + self.notes(for: entry, inventory: inventory)
            let note = entryNotes.isEmpty ? nil : entryNotes.joined(separator: "; ")
            return LeftoverCandidate(path: entry.path, kind: entry.kind, confidence: note == nil ? .safe : .uncertain,
                                     note: note, identity: entry.identity)
        }
        if vendorApps.isEmpty, vendorComponents.isEmpty, similarApps.isEmpty, !BundleIDShape.isSharedLibrary(bucket.identifier) {
            for folder in vendorFolders(for: bucket.identifier, inventory: inventory)
            where usedVendorFolders.insert(folder.path).inserted {
                candidates.append(folder)
                let name = (folder.path as NSString).lastPathComponent
                claims[folder.path] = OrphanClaim(
                    identifiers: [name, bucket.identifier],
                    vendorFolder: OrphanClaim.VendorFolder(name: name, groupIdentifier: bucket.identifier)
                )
            }
        }
        return OrphanGroup(identifier: bucket.identifier, candidates: candidates.sorted(by: LeftoverCandidate.displayOrder),
                           claims: claims)
    }

    /// Hinweise, die nur einen Eintrag betreffen: Team-Container ohne prüfbare Team-IDs, systemweiter Ort, App-Daten.
    ///
    /// Regel für App-Daten (Review N1): Container und Gruppen-Container sind **nie** vorausgewählt. Eine App auf einem
    /// gerade nicht angeschlossenen Laufwerk kennen weder das Inventar noch Spotlight („fehlt“), und ob ein solches
    /// Laufwerk existiert, lässt sich nicht belegen. Container enthalten bei sandboxed Apps die Dokumente des Nutzers –
    /// ein Fehlgriff wöge schwer; Caches, Einstellungen u. Ä. bleiben vorausgewählt (Papierkorb, „Zurücklegen“).
    private func notes(for entry: Entry, inventory: OrphanInventory) -> [String] {
        var notes: [String] = []
        if entry.team != nil && !inventory.allTeamsKnown { notes.append("Team-ID nicht bei allen Apps prüfbar") }
        if entry.isSystemWide { notes.append(Self.systemWideNote) }
        if [.container, .groupContainer].contains(entry.kind) { notes.append(Self.appDataNote) }
        return notes
    }

    /// Ordner mit dem Herstellernamen (`Application Support/OpenClaw` zu `ai.openclaw.mac`), unsicher; nur an Orten mit
    /// Namenstreffern, nie mit dem Namen einer installierten App, eines macOS-Ordners oder einem allgemeinen Namen.
    private func vendorFolders(for identifier: String, inventory: OrphanInventory) -> [LeftoverCandidate] {
        guard let token = VendorToken.of(identifier), !LeftoverMatcher.genericNames.contains(token),
              !LeftoverMatcher.appleFolderNames.contains(token), !inventory.hasApp(named: token) else { return [] }
        return layout.leftoverLocations.filter(\.allowsNameMatches).flatMap { location in
            (LeftoverScanner.entries(in: location.directory) ?? []).compactMap { name -> LeftoverCandidate? in
                guard LeftoverMatcher.normalized(name) == token, !inventory.owns(name) else { return nil }
                let path = location.directory + "/" + name
                guard case .allowed(let identity) = removalGuard.inspect(path, appleOwnerID: nil) else { return nil }
                return LeftoverCandidate(path: path, kind: location.kind, confidence: .uncertain,
                                         note: "Ordner nach Herstellername", identity: identity)
            }
        }
    }
}

/// Antworten von Launch Services/Spotlight je Kennung, höchstens eine Anfrage je Kennung und Suche.
private struct PresenceCache {
    let resolver: any AppResolving
    private var known: [String: Bool] = [:]

    init(resolver: any AppResolving) {
        self.resolver = resolver
    }

    /// `true` nur, wenn die Kennung als (vermutlich) entfernt gemeldet wird; `unknown` und vorhanden sind es nicht.
    mutating func isGone(_ identifier: String) async -> Bool {
        if let cached = known[identifier] { return cached }
        let presence = await resolver.resolve(bundleID: identifier).presence
        let gone = presence == .probablyMissing || presence == .missing
        known[identifier] = gone
        return gone
    }
}

private extension OrphanScanCoverage {
    var allowsCandidates: Bool {
        if case .unavailable = self { false } else { true }
    }

    var uncertaintyReason: String? {
        if case .incomplete(let reason) = self { reason } else { nil }
    }
}
