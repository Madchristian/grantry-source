import Foundation
import GrantryShared
import os

/// Scan-Quelle der Erweiterungen (TM-13.3, `SourceID.extensions`): Systemerweiterungen, Kernel-Erweiterungen von
/// Drittanbietern und Plug-ins in Systemdiensten – ohne Root und ohne Helper.
///
/// - Die drei Listen lesen eigene Leser gleichzeitig. Scheitert einer, liefern die übrigen weiter: Seine Liste gilt als
///   nicht gelesen (`ExtensionContribution.incompleteGroups`), ihre Einträge zeigen den letzten bekannten Stand, und ein
///   erneuter Scan kann es beheben. Erst wenn alle drei scheitern, scheitert die Quelle.
/// - Unvollständige Listen (nicht lesbare Zeilen, nicht auswertbare Bundles oder Ordner) sind Einschränkungen: Fehlende
///   Einträge der Liste bzw. an diesen Pfaden werden fortgeschrieben, statt als entfernt zu gelten.
/// - Die Signatur der Kernel-Erweiterungen prüft ein `CachingSigningInspector` auf `ExtensionWork.queue` mit Frist;
///   derselbe Puffer dient den Plug-ins, eine Instanz der Quelle prüft Unverändertes daher nur einmal.
///   Systemerweiterungen prüft macOS bei der Aktivierung, ihr Team liefert `systemextensionsctl`.
/// - Die zugehörige App ordnet `linkingRecords(in:)` zu, sobald die Apps desselben Scans vorliegen.
public struct ExtensionInventorySource: InventorySource {
    public let id = SourceID.extensions

    /// Eng zu beobachtende Ordner (`ScanTriggers`, `existingPaths`): installierte Kernel-Erweiterungen und die
    /// Plug-in-Ordner. Ein fehlender Ordner wird nicht über seinen Elternordner beobachtet (#279); ihn deckt der reguläre
    /// Scan ab.
    public static func watchedDirectories(home: String = NSHomeDirectory()) -> [String] {
        [InstalledKernelExtensionScanner.standardDirectory] + ServicePluginDirectory.standard(home: home).map(\.path)
    }

    /// Datenbank der Systemerweiterungen (für alle lesbar): Sie ändert sich, wenn eine Systemerweiterung installiert,
    /// freigegeben oder entfernt wird – nur als Scan-Auslöser, gelesen wird sie nie.
    public static let watchedFiles = ["/Library/SystemExtensions/db.plist"]

    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "extensions")

    private let systemExtensions: any SystemExtensionListing
    private let kernelExtensions: any KernelExtensionListing
    private let servicePlugins: any ServicePluginListing
    private let signing: any SigningInspecting
    private let ownerIndex: @Sendable ([InstalledApp]) async throws -> AppExtensionIndex
    private let now: @Sendable () -> Date

    public init(runner: any CommandRunning = ProcessCommandRunner(), home: String = NSHomeDirectory()) {
        let signing = CachingSigningInspector()
        self.init(
            systemExtensions: SystemExtensionReader(runner: runner),
            kernelExtensions: KernelExtensionReader(runner: runner, signing: signing),
            servicePlugins: ServicePluginReader(signing: signing, home: home), signing: signing,
            ownerIndex: { try await AppExtensionIndex.load(apps: $0) }, now: Date.init
        )
    }

    init(
        systemExtensions: any SystemExtensionListing, kernelExtensions: any KernelExtensionListing,
        servicePlugins: any ServicePluginListing, signing: any SigningInspecting,
        ownerIndex: @escaping @Sendable ([InstalledApp]) async throws -> AppExtensionIndex,
        now: @escaping @Sendable () -> Date
    ) {
        self.systemExtensions = systemExtensions
        self.kernelExtensions = kernelExtensions
        self.servicePlugins = servicePlugins
        self.signing = signing
        self.ownerIndex = ownerIndex
        self.now = now
    }

    public func collect() async throws -> InventoryContribution {
        let seenAt = now()
        async let system = Self.outcome { try await systemExtensions.systemExtensions() }
        async let kernel = Self.outcome { try await kernelRecords(seenAt: seenAt) }
        async let plugins = Self.outcome { try await servicePlugins.servicePlugins() }
        var collected = Collected()
        collected.add(await system, group: .systemExtensions, listName: "Systemerweiterungen") { list in
            Reading(records: ExtensionRecord.records(from: list, seenAt: seenAt), isListIncomplete: !list.isComplete)
        }
        collected.add(await kernel, group: .kernelExtensions, listName: "geladenen Kernel-Erweiterungen") { $0 }
        collected.add(await plugins, group: .servicePlugins, listName: "Plug-ins") { list in
            Reading(records: list.plugins.map { ExtensionRecord(plugin: $0, seenAt: seenAt) }, unreadable: list.unreadable)
        }
        if collected.failures.count == ExtensionGroup.allCases.count, let failure = collected.failures.first { throw failure }
        return InventoryContribution(
            extensions: collected.extensions, limitations: collected.limitations,
            retryableLimitations: collected.retryableLimitations
        )
    }

    /// Ordnet die Erweiterungen den Apps des Scans zu – nur, wenn die Apps nachweislich gelesen wurden: Ohne Apps wäre
    /// jede Erweiterung scheinbar verwaist. Scheitert das Lesen der App-Erweiterungen, bleibt die bisherige Zuordnung.
    public func linkingRecords(in snapshot: Snapshot) async -> Snapshot {
        guard !snapshot.extensions.isEmpty, snapshot.baselineSources.contains(.apps),
              !snapshot.failedSources.contains(.apps) else { return snapshot }
        do {
            return snapshot.assigningExtensionOwners(try await ownerIndex(snapshot.installedApps))
        } catch {
            Self.logger.error("Erweiterungen nicht zugeordnet: \(error.readableDescription, privacy: .public)")
            return snapshot
        }
    }

    /// Kernel-Erweiterungen mit Signatur; endet die Prüfung nicht rechtzeitig, gelten alle als nicht geprüft.
    private func kernelRecords(seenAt: Date) async throws -> Reading {
        let list = try await kernelExtensions.kernelExtensions()
        let signing = signing
        let records = await ExtensionWork.queue.run {
            ExtensionWork.fileSystemGuard.run(timeout: ExtensionWork.timeout) {
                ExtensionRecord.records(from: list, seenAt: seenAt, inspect: signing.inspection(ofPath:))
            }
        }
        return Reading(
            records: records ?? ExtensionRecord.records(from: list, seenAt: seenAt) { _ in .timedOut },
            isListIncomplete: list.unreadableLoadedLineCount > 0, unreadable: list.unreadable
        )
    }

    private static func outcome<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}

/// Ergebnis eines Lesers: Einträge und was er nicht vollständig lesen konnte.
private struct Reading: Sendable {
    var records: [ExtensionRecord]
    /// Die Liste selbst ist nur ein Ausschnitt (nicht lesbare Zeilen ohne Pfad).
    var isListIncomplete = false
    /// Nicht auswertbare Bundles oder Ordner.
    var unreadable: [UnreadableExtension] = []
}

/// Sammelt die Ergebnisse der drei Leser zu einem Beitrag samt Einschränkungen.
private struct Collected {
    var extensions = ExtensionContribution()
    var limitations: [String] = []
    var retryableLimitations: [String] = []
    var failures: [any Error] = []

    mutating func add<List>(
        _ outcome: Result<List, any Error>, group: ExtensionGroup, listName: String, reading: (List) -> Reading
    ) {
        switch outcome {
        case .success(let list):
            let result = reading(list)
            extensions.records += result.records
            if result.isListIncomplete {
                extensions.incompleteGroups.insert(group)
                limitations.append("Liste der \(listName) unvollständig – fehlende Einträge zeigen den letzten bekannten Stand")
            }
            extensions.incompletePaths += result.unreadable.map(\.path)
            limitations += result.unreadable.map { "\(PathDisplay.abbreviatingHome($0.path)) nicht auswertbar: \($0.reason)" }
        case .failure(let error):
            failures.append(error)
            extensions.incompleteGroups.insert(group)
            retryableLimitations.append(
                "\(group.displayName) nicht gelesen: \(error.readableDescription) – zuletzt bekannter Stand gilt weiter"
            )
        }
    }
}
