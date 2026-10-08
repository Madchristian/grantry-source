import Foundation

/// Installierte Apps für den Abgleich der Reste gelöschter Apps: alle Apps des Snapshots (auch Duplikate und Apps, die
/// gerade fehlen) **und** die App-Bundles, die jetzt unter den App-Wurzeln liegen (`AppInventorySource.scan`, auch
/// versteckte und seit dem letzten Scan neue). Neue Bundles und Ziele von Symlink-Bundles werden nur über ihre
/// `Info.plist` gelesen (ohne Blockieren, ohne Systemdienste, keine Signaturprüfung des Ziels).
///
/// Dazu Komponenten ohne `.app` (Review M1) als Besitzer und Namensraum: Autostart-Einträge, deren Programm vorhanden
/// ist (Label und Bundle-ID des Besitzers), sowie `ComponentInventory` (Systemeinstellungen, Bildschirmschoner,
/// Audio-Plug-ins, Kernel-Erweiterungen, `PrivilegedHelperTools`). Hat ein Hersteller solche Komponenten, ist jeder
/// seiner Funde unsicher (`vendorComponents`).
///
/// Belastbarkeit (`OrphanScanCoverage`):
/// - Ohne App-Inventar im Snapshot (Quelle nie geliefert oder fehlgeschlagen) oder mit nicht lesbarer App-Wurzel ist
///   nichts belegt: `unavailable` – der Scanner bietet keine Gruppen an. Ein Rest einer installierten App wäre sonst
///   „sicher“ (vorausgewählt), und Launch Services/Spotlight allein schließen das nicht aus (Spotlight-Ausschlüsse,
///   nicht registrierte Apps).
/// - Nicht lesbare Unterordner und Bundles ohne lesbare Bundle-ID (auch Symlink-Bundles mit fehlendem Ziel): `incomplete`
///   – ein Teil fehlt, die Funde bleiben sichtbar, aber unsicher und nicht vorausgewählt.
struct OrphanInventory {
    /// Name und Bundle-ID einer installierten App.
    struct KnownApp: Equatable {
        let name: String
        let bundleID: String?
        /// Normalisierte Namen für den Abgleich mit Kennungs-Bestandteilen: Anzeigename, Bundle-Name ohne `.app`,
        /// Herstellerbestandteil und letzter Bestandteil der Bundle-ID (`de.cstrube.ACCpromAdapter` → `accpromadapter`),
        /// je mindestens `LeftoverMatcher.minimumNameLength` Zeichen und kein allgemeiner Name.
        let matchNames: Set<String>

        init(name: String, path: String, bundleID: String?) {
            self.name = name
            self.bundleID = bundleID
            let stem = RawPath.hasExtension(path, "app") ? String((path as NSString).lastPathComponent.dropLast(".app".count)) : nil
            let lastComponent = bundleID?.split(separator: ".").last.map(String.init)
            matchNames = Set([name, stem, bundleID.flatMap(VendorToken.of), lastComponent].compactMap { $0 }
                .map(LeftoverMatcher.normalized)
                .filter { $0.count >= LeftoverMatcher.minimumNameLength && !LeftoverMatcher.genericNames.contains($0) })
        }
    }

    let coverage: OrphanScanCoverage
    /// Installierte Komponenten ohne `.app` (Kennung und Name für Hinweise).
    private let components: [ComponentInventory.Component]
    /// Team-IDs installierter Apps.
    var teams: Set<String> { Set(teamOwners.keys) }
    /// Team-ID → Name einer installierten App mit dieser Team-ID.
    private let teamOwners: [String: String]
    /// Jede App hat eine bekannte Team-ID oder nachweislich keine (`LeftoverMatcher.hasKnownTeam`); Bundles nur von der
    /// Platte (ohne Signaturprüfung) zählen als unbekannt.
    let allTeamsKnown: Bool
    private let apps: [KnownApp]
    private let ownership: BundleIDOwnership
    /// Bundle-IDs (klein) für den Namensraum-Abgleich.
    private let bundleIDs: [String]
    /// Bundle-ID bzw. Kennung (klein) → Name der App oder Komponente; Apps vor Komponenten.
    private let ownerNames: [String: String]

    init(snapshot: Snapshot, layout: LibraryLayout, names: any AppNameReading = BundleNameReader()) {
        guard snapshot.baselineSources.contains(.apps), !snapshot.failedSources.contains(.apps) else {
            self.init(coverage: .unavailable("App-Inventar liegt nicht vor"), apps: [], teams: [:], allTeamsKnown: false)
            return
        }
        let byPath = Dictionary(snapshot.installedApps.map { ($0.path, $0) }) { first, _ in first }
        var apps = snapshot.installedApps.map { KnownApp(name: $0.name, path: $0.path, bundleID: $0.bundleID) }
        var allTeamsKnown = snapshot.installedApps.allSatisfy(LeftoverMatcher.hasKnownTeam)
        var unreadableFolders = 0, unknownBundles = 0
        for root in layout.appRoots {
            let scan = AppInventorySource.scan(root: root)
            if let canonical = AppleComponent.canonicalPath(root), scan.unreadableFolders.contains(canonical) {
                self.init(coverage: .unavailable("App-Ordner nicht lesbar: \(PathDisplay.abbreviatingHome(root))"),
                          apps: [], teams: [:], allTeamsKnown: false)
                return
            }
            unreadableFolders += scan.unreadableFolders.count
            for entry in scan.entries {
                if byPath[entry.path]?.bundleID != nil { continue }
                // Symlink-Bundles (`/Applications/Safari.app` → Cryptex): nur die `Info.plist` des Ziels, wie bei Bundles.
                let bundle = switch entry {
                case .bundle(let path): path
                case .symlink(_, let target): target
                }
                guard let info = AppBundleReader.read(bundleAt: bundle, names: names), let bundleID = info.bundleID else {
                    unknownBundles += 1
                    continue
                }
                apps.append(KnownApp(name: info.name, path: entry.path, bundleID: bundleID))
                allTeamsKnown = false
            }
        }
        let installed = ComponentInventory(layout: layout)
        let autostart = snapshot.autostartItems.filter { $0.programPresence == .present }.flatMap { item in
            [item.label, item.owner?.bundleID].compactMap(\.self).map { ComponentInventory.Component(identifier: $0, name: $0) }
        }
        self.init(
            coverage: Self.coverage(unreadableFolders: unreadableFolders, unknownBundles: unknownBundles,
                                    unreadableComponentFolders: installed.unreadableFolders),
            apps: apps, components: installed.components + autostart,
            teams: Dictionary(snapshot.installedApps.compactMap { app in app.signing.teamID.map { ($0, app.name) } }) { first, _ in first },
            allTeamsKnown: allTeamsKnown
        )
    }

    init(
        coverage: OrphanScanCoverage, apps: [KnownApp], components: [ComponentInventory.Component] = [],
        teams: [String: String], allTeamsKnown: Bool
    ) {
        self.coverage = coverage
        self.apps = apps
        self.components = components
        teamOwners = teams
        self.allTeamsKnown = allTeamsKnown
        bundleIDs = apps.compactMap { $0.bundleID?.lowercased() } + components.map { $0.identifier.lowercased() }
        ownership = BundleIDOwnership(bundleIDs: bundleIDs)
        let named = apps.compactMap { app in app.bundleID.map { ($0.lowercased(), app.name) } }
            + components.map { ($0.identifier.lowercased(), $0.name) }
        ownerNames = Dictionary(named) { first, _ in first }
    }

    private static func coverage(unreadableFolders: Int, unknownBundles: Int, unreadableComponentFolders: Int) -> OrphanScanCoverage {
        var parts: [String] = []
        if unreadableFolders > 0 { parts.append("\(unreadableFolders) Ordner nicht lesbar") }
        if unknownBundles > 0 { parts.append("\(unknownBundles) \(unknownBundles == 1 ? "App" : "Apps") ohne bekannte Bundle-ID") }
        if unreadableComponentFolders > 0 { parts.append("\(unreadableComponentFolders) Komponenten-Ordner nicht lesbar") }
        return parts.isEmpty ? .complete : .incomplete("App-Inventar unvollständig: " + parts.joined(separator: ", "))
    }

    /// `identifier` gehört einer installierten App oder Komponente (`BundleIDOwnership`) oder ist der Namensraum einer
    /// (`io.github.wickenico` zu `io.github.wickenico.wailbrew`).
    func owns(_ identifier: String) -> Bool {
        ownerName(of: identifier) != nil
    }

    /// Name der App oder Komponente, der `identifier` gehört bzw. deren Namensraum er ist (Regeln wie `owns`).
    func ownerName(of identifier: String) -> String? {
        let lowered = identifier.lowercased()
        let owner = ownership.owner(of: lowered) ?? bundleIDs.first { $0.utf8.starts(with: (lowered + ".").utf8) }
        return owner.map { ownerNames[$0] ?? $0 }
    }

    /// Name einer installierten App mit der Team-ID `team`.
    func appName(withTeam team: String) -> String? {
        teamOwners[team]
    }

    /// Namen installierter Apps desselben Herstellers (`VendorToken`), sortiert.
    func vendorApps(of identifier: String) -> [String] {
        guard let token = VendorToken.of(identifier) else { return [] }
        return Self.sortedNames(apps.filter { $0.bundleID.flatMap(VendorToken.of) == token })
    }

    /// Namen installierter Komponenten desselben Herstellers (`VendorToken`), sortiert.
    func vendorComponents(of identifier: String) -> [String] {
        guard let token = VendorToken.of(identifier) else { return [] }
        return Set(components.filter { VendorToken.of($0.identifier) == token }.map(\.name)).sorted()
    }

    /// Namen installierter Apps, von denen ein Name (`KnownApp.matchNames`) ein Bestandteil von `identifier` ist
    /// (`warp.log.old.0` zu Warp, `de.strube.ACCpromAdapter` zu `de.cstrube.ACCpromAdapter`); sortiert.
    func appsNamed(in identifier: String) -> [String] {
        let parts = Set(identifier.split(separator: ".").map { LeftoverMatcher.normalized(String($0)) })
        return Self.sortedNames(apps.filter { !$0.matchNames.isDisjoint(with: parts) })
    }

    /// Eine installierte App trägt `name` (`KnownApp.matchNames`, ohne Groß-/Kleinschreibung und diakritische Zeichen).
    func hasApp(named name: String) -> Bool {
        appName(named: name) != nil
    }

    /// Name der installierten App, die `name` trägt (wie `hasApp(named:)`).
    func appName(named name: String) -> String? {
        let name = LeftoverMatcher.normalized(name)
        return apps.first { $0.matchNames.contains(name) }?.name
    }

    private static func sortedNames(_ apps: [KnownApp]) -> [String] {
        Set(apps.map(\.name)).sorted()
    }
}
