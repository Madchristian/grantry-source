import GrantryShared
import os

/// Liefert die Kernel-Erweiterungen von Drittanbietern; in Tests ersetzbar.
public protocol KernelExtensionListing: Sendable {
    func kernelExtensions() async throws -> KernelExtensionList
}

/// Geladene Kernel-Erweiterungen über IOKit (Rückfall `kmutil showloaded`) und installierte aus `/Library/Extensions`,
/// ohne Root und ohne private Schnittstellen. Apple-eigene blendet `AppleKernelExtensionFilter` aus.
///
/// Scheitern beide Quellen der geladenen, scheitert der Leser – eine leere Liste würde sonst „keine Kernel-
/// Erweiterungen“ melden. Ordner, Info.plists und Signaturprüfung laufen auf `ExtensionWork.queue` mit Frist; endet der
/// Auftrag nicht rechtzeitig, scheitert der Leser ebenfalls.
public struct KernelExtensionReader: KernelExtensionListing {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "extensions")

    private let primary: any LoadedKernelExtensionProviding
    private let fallback: any LoadedKernelExtensionProviding
    private let installed: InstalledKernelExtensionScanner
    private let signing: any SigningInspecting

    public init(runner: any CommandRunning = ProcessCommandRunner(), signing: any SigningInspecting = SecuritySigningInspector()) {
        self.init(
            primary: KextManagerLoadedProvider(), fallback: KmutilLoadedProvider(runner: runner),
            installed: InstalledKernelExtensionScanner(), signing: signing
        )
    }

    init(
        primary: any LoadedKernelExtensionProviding, fallback: any LoadedKernelExtensionProviding,
        installed: InstalledKernelExtensionScanner, signing: any SigningInspecting
    ) {
        self.primary = primary
        self.fallback = fallback
        self.installed = installed
        self.signing = signing
    }

    public func kernelExtensions() async throws -> KernelExtensionList {
        let loaded = try await loadedExtensions()
        let filter = AppleKernelExtensionFilter(signing: signing)
        let scanner = installed
        let result = await ExtensionWork.queue.run {
            ExtensionWork.fileSystemGuard.run(timeout: ExtensionWork.timeout) {
                let scan = scanner.scan()
                return KernelExtensionList(
                    loaded: loaded.records.filter { !filter.isApple($0) }.map {
                        KernelExtension(bundleID: $0.bundleID, version: $0.version, name: nil, path: $0.path)
                    },
                    installed: scan.extensions.filter { !filter.isApple($0) },
                    loadedSource: loaded.source,
                    unreadable: scan.unreadable,
                    unreadableLoadedLineCount: loaded.unreadableLineCount
                )
            }
        }
        guard let result else {
            throw ExtensionReadError.unavailable("\(InstalledKernelExtensionScanner.standardDirectory) nicht rechtzeitig gelesen")
        }
        return result
    }

    private func loadedExtensions() async throws -> LoadedKernelExtensions {
        do {
            return try await primary.loadedExtensions()
        } catch {
            Self.logger.error("Geladene Kernel-Erweiterungen über kmutil: \(error.readableDescription, privacy: .public)")
            return try await fallback.loadedExtensions()
        }
    }
}
