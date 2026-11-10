import Foundation

/// Liefert die Plug-ins der Systemdienste; in Tests ersetzbar.
public protocol ServicePluginListing: Sendable {
    func servicePlugins() async throws -> ServicePluginList
}

/// Audio- und Video-Plug-ins der Systemdienste mit Signatur, Notarisierung, Team und Entwicklername – ohne Root und
/// ohne Helper.
///
/// Ordner, Info.plists und Signaturprüfung laufen auf `ExtensionWork.queue` mit Frist; endet der Auftrag nicht
/// rechtzeitig, scheitert der Leser. Die Signatur prüft standardmäßig ein `CachingSigningInspector`: Eine Instanz des
/// Lesers prüft ein unverändertes Plug-in nur beim ersten Scan; der Aufrufer behält sie deshalb über die Scans hinweg.
public struct ServicePluginReader: ServicePluginListing {
    private let scanner: ServicePluginScanner
    private let signing: any SigningInspecting

    public init(signing: any SigningInspecting = CachingSigningInspector(), home: String = NSHomeDirectory()) {
        self.init(scanner: ServicePluginScanner(directories: ServicePluginDirectory.standard(home: home)), signing: signing)
    }

    init(scanner: ServicePluginScanner, signing: any SigningInspecting) {
        self.scanner = scanner
        self.signing = signing
    }

    public func servicePlugins() async throws -> ServicePluginList {
        let scanner = scanner
        let signing = signing
        let result = await ExtensionWork.queue.run {
            ExtensionWork.fileSystemGuard.run(timeout: ExtensionWork.timeout) {
                let scan = scanner.scan()
                return ServicePluginList(
                    plugins: scan.bundles.map { Self.plugin($0, inspection: signing.inspection(ofPath: $0.bundle.path)) },
                    unreadable: scan.unreadable
                )
            }
        }
        guard let result else { throw ExtensionReadError.unavailable("Plug-in-Ordner nicht rechtzeitig gelesen") }
        return result
    }

    private static func plugin(_ entry: ServicePluginScanner.Entry, inspection: SigningInspection) -> ServicePlugin {
        var signing = inspection.info
        signing.developerName = signing.developerName.map(ExtensionText.name)
        return ServicePlugin(
            kind: entry.directory.kind, location: entry.directory.location, bundleID: entry.bundle.bundleID,
            version: entry.bundle.version, name: entry.bundle.name, path: entry.bundle.path, signing: signing,
            isSigningConclusive: inspection.isConclusive
        )
    }
}
