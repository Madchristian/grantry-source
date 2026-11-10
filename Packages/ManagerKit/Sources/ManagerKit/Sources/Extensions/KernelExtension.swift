/// Eine Kernel-Erweiterung eines Drittanbieters – geladen oder in `/Library/Extensions` installiert.
///
/// Bundle-ID, Version und Name stammen vom Hersteller und sind einzeilig und gekürzt (`DisplayText.singleLine`); der
/// Pfad bleibt unverändert, weil er auf das Bundle zeigt.
public struct KernelExtension: Hashable, Sendable {
    public let bundleID: String
    /// `CFBundleShortVersionString`, ersatzweise `CFBundleVersion`.
    public let version: String?
    /// `CFBundleName`; für geladene Erweiterungen unbekannt.
    public let name: String?
    /// Bundle-Pfad; für geladene Erweiterungen aus dem Rückfall `kmutil` unbekannt.
    public let path: String?

    public init(bundleID: String, version: String?, name: String?, path: String?) {
        self.bundleID = bundleID
        self.version = version
        self.name = name
        self.path = path
    }
}

/// Eine Erweiterung, die vorhanden, aber nicht auswertbar ist (Grund ohne Inhalt).
public struct UnreadableExtension: Hashable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Woher die Liste der geladenen Kernel-Erweiterungen stammt.
public enum LoadedKernelExtensionSource: Hashable, Sendable {
    /// `KextManagerCopyLoadedKextInfo` (IOKit, öffentlich).
    case kextManager
    /// Rückfall `kmutil showloaded`, wenn IOKit nichts liefert.
    case kmutil
}

/// Kernel-Erweiterungen von Drittanbietern; Apple-eigene sind ausgeblendet (`AppleKernelExtensionFilter`).
public struct KernelExtensionList: Hashable, Sendable {
    public let loaded: [KernelExtension]
    public let installed: [KernelExtension]
    public let loadedSource: LoadedKernelExtensionSource
    /// Installierte Bundles, die nicht auswertbar waren, oder der Ordner selbst.
    public let unreadable: [UnreadableExtension]
    /// Nicht auswertbare Zeilen aus `kmutil showloaded`.
    public let unreadableLoadedLineCount: Int

    public init(
        loaded: [KernelExtension], installed: [KernelExtension], loadedSource: LoadedKernelExtensionSource,
        unreadable: [UnreadableExtension] = [], unreadableLoadedLineCount: Int = 0
    ) {
        self.loaded = loaded
        self.installed = installed
        self.loadedSource = loadedSource
        self.unreadable = unreadable
        self.unreadableLoadedLineCount = unreadableLoadedLineCount
    }

    /// `true`, wenn nichts übersprungen wurde; sonst ist die Liste nur ein Ausschnitt.
    public var isComplete: Bool { unreadable.isEmpty && unreadableLoadedLineCount == 0 }
}

/// Eine geladene Kernel-Erweiterung vor dem Ausblenden der Apple-eigenen.
struct LoadedKernelExtensionRecord: Hashable, Sendable {
    let bundleID: String
    let version: String?
    let path: String?
    /// Teil des Kerns selbst (`OSKernelResource`, bei `kmutil` ohne eigene Ladeadresse).
    let isKernelResource: Bool
}

/// Geladene Kernel-Erweiterungen einer Quelle.
struct LoadedKernelExtensions: Hashable, Sendable {
    let records: [LoadedKernelExtensionRecord]
    let source: LoadedKernelExtensionSource
    var unreadableLineCount = 0
}

/// Liefert die geladenen Kernel-Erweiterungen; in Tests ersetzbar.
protocol LoadedKernelExtensionProviding: Sendable {
    func loadedExtensions() async throws -> LoadedKernelExtensions
}
