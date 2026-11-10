/// Plug-in-Bundles der Systemdienst-Ordner (`ServicePluginDirectory.standard`), nur auf lokalen Volumes und ohne
/// Symlinks zu folgen (`ExtensionVolumeCheck`, `ExtensionBundleScanner`). Synchron und blockierend; der Aufrufer lagert
/// ihn aus (`ServicePluginReader`).
struct ServicePluginScanner: Sendable {
    /// Audio-Server-Plug-ins heißen `*.driver`, DAL-Plug-ins `*.plugin`; manche Hersteller weichen ab.
    static let bundleSuffixes = [".driver", ".plugin", ".bundle"]
    static let defaultMaximumEntries = 200

    struct Entry: Hashable, Sendable {
        let directory: ServicePluginDirectory
        let bundle: ExtensionBundle
    }

    struct Scan: Hashable, Sendable {
        var bundles: [Entry] = []
        var unreadable: [UnreadableExtension] = []
    }

    let directories: [ServicePluginDirectory]
    let volumeCheck: ExtensionVolumeCheck
    let maximumEntries: Int

    init(
        directories: [ServicePluginDirectory], volumes: @escaping @Sendable () -> [MountedVolume] = MountedVolume.current,
        maximumEntries: Int = defaultMaximumEntries
    ) {
        self.directories = directories
        self.volumeCheck = ExtensionVolumeCheck(volumes: volumes)
        self.maximumEntries = maximumEntries
    }

    func scan() -> Scan {
        var scan = Scan()
        let volumes = volumeCheck.snapshot()
        for directory in directories {
            if let reason = volumes.refusal(forPath: directory.path) {
                scan.unreadable.append(UnreadableExtension(path: directory.path, reason: reason))
                continue
            }
            let found = ExtensionBundleScanner(directory: directory.path, suffixes: Self.bundleSuffixes, maximumEntries: maximumEntries).scan()
            scan.bundles += found.bundles.map { Entry(directory: directory, bundle: $0) }
            scan.unreadable += found.unreadable
        }
        return scan
    }
}
