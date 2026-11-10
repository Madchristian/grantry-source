import Foundation

extension ExtensionRecord {
    /// Je Systemerweiterung (Team-ID und Bundle-ID) ein Eintrag mit der maßgeblichen Zeile: zuerst nach Zustand (aktiv,
    /// wartet auf Freigabe, deaktiviert, unbekannt, wird entfernt), dann die neueste Version. Die übrigen Zeilen – meist
    /// alte Versionen, die auf den Neustart warten – stehen in `otherVersions`. Sortiert nach Identität.
    static func records(from list: SystemExtensionList, seenAt: Date) -> [ExtensionRecord] {
        let groups = Dictionary(grouping: list.extensions) { RecordIdentity.join([$0.teamID ?? "", $0.bundleID]) }
        return groups.values.map { rows in
            let ordered = rows.sorted(by: Self.precedes)
            let main = ordered[0]
            return ExtensionRecord(
                kind: ExtensionKind(main.category), bundleID: main.bundleID, teamID: main.teamID, name: main.name,
                version: main.version, buildVersion: main.buildVersion, state: ExtensionState(main.state),
                otherVersions: ordered.dropFirst().sorted { Self.isNewer($0, than: $1) }.map(\.version), firstSeenAt: seenAt
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Geladene und installierte Kernel-Erweiterungen, über die Bundle-ID zusammengeführt (je Bundle-ID die erste
    /// Fassung): Version der geladenen, Name und Pfad der installierten; die Signatur prüft `inspect` am Pfad. Sortiert
    /// nach Bundle-ID.
    static func records(
        from list: KernelExtensionList, seenAt: Date, inspect: (String) -> SigningInspection
    ) -> [ExtensionRecord] {
        let loaded = Dictionary(list.loaded.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        let installed = Dictionary(list.installed.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(loaded.keys).union(installed.keys).sorted().map { bundleID in
            let running = loaded[bundleID], onDisk = installed[bundleID]
            let path = onDisk?.path ?? running?.path
            let inspection = path.map(inspect)
            return ExtensionRecord(
                kind: .kernelExtension, bundleID: bundleID, teamID: inspection?.info.teamID, name: onDisk?.name,
                version: running?.version ?? onDisk?.version, buildVersion: nil, state: running == nil ? .notLoaded : .loaded,
                signing: inspection?.info, isSigningConclusive: inspection != .timedOut, path: path, firstSeenAt: seenAt
            )
        }
    }

    init(plugin: ServicePlugin, seenAt: Date) {
        self.init(
            kind: plugin.kind == .audio ? .audioPlugin : .videoPlugin, bundleID: plugin.bundleID, teamID: plugin.signing.teamID,
            name: plugin.name, version: plugin.version, buildVersion: nil, state: .installed, signing: plugin.signing,
            isSigningConclusive: plugin.isSigningConclusive, path: plugin.path, firstSeenAt: seenAt
        )
    }

    /// Maßgebliche Zeile zuerst: besserer Zustand, dann neuere Version.
    private static func precedes(_ lhs: SystemExtension, _ rhs: SystemExtension) -> Bool {
        let (left, right) = (rank(of: lhs.state), rank(of: rhs.state))
        return left != right ? left < right : isNewer(lhs, than: rhs)
    }

    private static func rank(of state: SystemExtensionState) -> Int {
        switch state {
        case .activatedEnabled: 0
        case .activatedWaitingForUser: 1
        case .activatedDisabled: 2
        case .unknown: 3
        case .terminatedWaitingToUninstallOnReboot: 4
        }
    }

    /// Version, dann Build numerisch verglichen („1.10“ ist neuer als „1.9“).
    private static func isNewer(_ lhs: SystemExtension, than rhs: SystemExtension) -> Bool {
        let version = lhs.version.compare(rhs.version, options: .numeric)
        guard version == .orderedSame else { return version == .orderedDescending }
        return (lhs.buildVersion ?? "").compare(rhs.buildVersion ?? "", options: .numeric) == .orderedDescending
    }
}

extension ExtensionKind {
    init(_ category: SystemExtensionCategory) {
        switch category {
        case .driver: self = .driver
        case .network: self = .network
        case .endpointSecurity: self = .endpointSecurity
        case .camera: self = .camera
        case .unknown(let identifier): self = .otherSystemExtension(identifier)
        }
    }
}

extension ExtensionState {
    init(_ state: SystemExtensionState) {
        switch state {
        case .activatedEnabled: self = .enabled
        case .activatedDisabled: self = .disabled
        case .activatedWaitingForUser: self = .waitingForUser
        case .terminatedWaitingToUninstallOnReboot: self = .removalPending
        case .unknown(let text): self = .unknown(text)
        }
    }
}
