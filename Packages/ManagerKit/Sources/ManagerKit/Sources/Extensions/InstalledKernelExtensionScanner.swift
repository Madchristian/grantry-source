/// Installierte Kernel-Erweiterungen aus `/Library/Extensions`: je `*.kext` die `Contents/Info.plist`
/// (`ExtensionBundleScanner`, ohne Symlinks zu folgen).
struct InstalledKernelExtensionScanner: Sendable {
    static let standardDirectory = "/Library/Extensions"
    static let defaultMaximumEntries = 1_000

    struct Scan: Hashable, Sendable {
        var extensions: [KernelExtension] = []
        var unreadable: [UnreadableExtension] = []
    }

    private let bundles: ExtensionBundleScanner

    init(directory: String = standardDirectory, maximumEntries: Int = defaultMaximumEntries) {
        bundles = ExtensionBundleScanner(directory: directory, suffixes: [".kext"], maximumEntries: maximumEntries)
    }

    func scan() -> Scan {
        let scan = bundles.scan()
        return Scan(
            extensions: scan.bundles.map { KernelExtension(bundleID: $0.bundleID, version: $0.version, name: $0.name, path: $0.path) },
            unreadable: scan.unreadable
        )
    }
}
