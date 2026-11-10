import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Liefert eine feste Liste oder scheitert.
private struct FixedSystemExtensions: SystemExtensionListing {
    let result: Result<SystemExtensionList, ExtensionReadError>
    func systemExtensions() async throws -> SystemExtensionList { try result.get() }
}

private struct FixedKernelExtensions: KernelExtensionListing {
    let result: Result<KernelExtensionList, ExtensionReadError>
    func kernelExtensions() async throws -> KernelExtensionList { try result.get() }
}

private struct FixedServicePlugins: ServicePluginListing {
    let result: Result<ServicePluginList, ExtensionReadError>
    func servicePlugins() async throws -> ServicePluginList { try result.get() }
}

/// Zählt, wie oft der App-Index geladen wird.
private final class IndexLoads: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func record() { count.withLock { $0 += 1 } }
}

@Suite struct ExtensionInventorySourceTests {
    private static let systemList = SystemExtensionList(
        extensions: [ExtensionRecordTests.systemExtension()], declaredCount: 1, unreadableLineCount: 0
    )
    private static let kernelList = KernelExtensionList(
        loaded: [], installed: [KernelExtension(bundleID: "com.vendor.kext", version: "1", name: "K", path: "/Library/Extensions/K.kext")],
        loadedSource: .kextManager
    )
    private static let pluginList = ServicePluginList(plugins: [ExtensionRecordTests.plugin(path: "/Library/Audio/Plug-Ins/HAL/A.driver")])
    private static let kextSigning = SigningInfo(kind: .developerID, teamID: "TEAMKEXT01", isNotarized: true)
    private static let failure = ExtensionReadError.unavailable("nicht rechtzeitig")

    private func source(
        system: Result<SystemExtensionList, ExtensionReadError> = .success(systemList),
        kernel: Result<KernelExtensionList, ExtensionReadError> = .success(kernelList),
        plugins: Result<ServicePluginList, ExtensionReadError> = .success(pluginList),
        signing: any SigningInspecting = ScriptedSigningInspector([.completed(kextSigning)]),
        index: @escaping @Sendable ([InstalledApp]) async throws -> AppExtensionIndex = { apps in
            AppExtensionIndex(apps: apps, embedded: [:], unreadable: [])
        }
    ) -> ExtensionInventorySource {
        ExtensionInventorySource(
            systemExtensions: FixedSystemExtensions(result: system), kernelExtensions: FixedKernelExtensions(result: kernel),
            servicePlugins: FixedServicePlugins(result: plugins), signing: signing, ownerIndex: index,
            now: { TestData.date }
        )
    }

    @Test func collectsAllThreeLists() async throws {
        let contribution = try await source().collect()
        #expect(contribution.extensions.records.map(\.kind) == [.network, .kernelExtension, .audioPlugin])
        #expect(contribution.extensions.records.first { $0.kind == .kernelExtension }?.signing == Self.kextSigning)
        #expect(contribution.extensions.incompleteGroups.isEmpty)
        #expect(contribution.extensions.incompletePaths.isEmpty)
        #expect(contribution.limitations.isEmpty)
        #expect(contribution.retryableLimitations.isEmpty)
    }

    /// Scheitert ein Leser, liefern die anderen weiter; seine Liste gilt als nicht gelesen (fortgeschrieben), und ein
    /// erneuter Scan kann es beheben.
    @Test func failingReaderMarksItsGroupIncomplete() async throws {
        let contribution = try await source(system: .failure(Self.failure)).collect()
        #expect(contribution.extensions.records.map(\.kind) == [.kernelExtension, .audioPlugin])
        #expect(contribution.extensions.incompleteGroups == [.systemExtensions])
        #expect(contribution.retryableLimitations == [
            "Systemerweiterungen nicht gelesen: Erweiterungen nicht lesbar: nicht rechtzeitig – zuletzt bekannter Stand gilt weiter",
        ])
    }

    @Test func allReadersFailingFailsTheSource() async {
        let source = source(system: .failure(Self.failure), kernel: .failure(Self.failure), plugins: .failure(Self.failure))
        await #expect(throws: ExtensionReadError.self) { try await source.collect() }
    }

    /// Unvollständige Listen: Systemerweiterungen und geladene Kexts ohne Pfadangabe halten die ganze Liste, nicht
    /// auswertbare Bundles und Ordner nur ihre Pfade.
    @Test func incompleteListsAreReportedAsGapsWithoutFailing() async throws {
        let system = SystemExtensionList(extensions: [], declaredCount: 1, unreadableLineCount: 1)
        let kernel = KernelExtensionList(
            loaded: [], installed: [], loadedSource: .kmutil,
            unreadable: [UnreadableExtension(path: "/Library/Extensions/Broken.kext", reason: "Info.plist fehlt")],
            unreadableLoadedLineCount: 2
        )
        let plugins = ServicePluginList(plugins: [], unreadable: [
            UnreadableExtension(path: "/Library/CoreMediaIO/Plug-Ins/DAL", reason: "Ordner nicht lesbar"),
        ])
        let contribution = try await source(system: .success(system), kernel: .success(kernel), plugins: .success(plugins)).collect()
        #expect(contribution.extensions.incompleteGroups == [.systemExtensions, .kernelExtensions])
        #expect(contribution.extensions.incompletePaths == ["/Library/Extensions/Broken.kext", "/Library/CoreMediaIO/Plug-Ins/DAL"])
        #expect(contribution.limitations == [
            "Liste der Systemerweiterungen unvollständig – fehlende Einträge zeigen den letzten bekannten Stand",
            "Liste der geladenen Kernel-Erweiterungen unvollständig – fehlende Einträge zeigen den letzten bekannten Stand",
            "/Library/Extensions/Broken.kext nicht auswertbar: Info.plist fehlt",
            "/Library/CoreMediaIO/Plug-Ins/DAL nicht auswertbar: Ordner nicht lesbar",
        ])
    }

    // MARK: Zuordnung im Scan

    private static let vendorApp = TestData.installedApp(
        "Vendor", bundleID: "com.vendor.app", signing: SigningInfo(kind: .developerID, teamID: "TEAMSYS001", isNotarized: true)
    )

    private static func coordinator(_ extensions: ExtensionInventorySource, apps: Result<InventoryContribution, TestFailure>) -> ScanCoordinator {
        ScanCoordinator(sources: [FixedSource(id: .apps, result: apps), extensions], now: { TestData.date })
    }

    /// Der Scan ordnet die Erweiterungen den Apps desselben Scans zu.
    @Test func scanAssignsOwnersFromTheAppsOfTheSameScan() async throws {
        let extensions = source(index: { apps in
            AppExtensionIndex(apps: apps, embedded: [Self.vendorApp.path: ["com.vendor.filter"]], unreadable: [])
        })
        let snapshot = try await Self.coordinator(extensions, apps: .success(InventoryContribution(installedApps: [Self.vendorApp])))
            .scan()
        let owners = Dictionary(uniqueKeysWithValues: snapshot.extensions.map { ($0.kind, $0.owner) })
        #expect(owners[.network] == .app(path: Self.vendorApp.path, evidence: .bundleID))
        #expect(owners[.kernelExtension] == .missing)
        #expect(snapshot.baselineSources.contains(.extensions))
    }

    /// Ohne gelieferte Apps ist „App fehlt“ nicht belegt: Die Zuordnung bleibt aus, statt alles als verwaist zu melden.
    @Test func withoutDeliveredAppsOwnersStayUnassigned() async throws {
        let loads = IndexLoads()
        let extensions = source(index: { apps in
            loads.record()
            return AppExtensionIndex(apps: apps, embedded: [:], unreadable: [])
        })
        let snapshot = try await Self.coordinator(extensions, apps: .failure(TestFailure())).scan()
        #expect(snapshot.extensions.allSatisfy { $0.owner == nil })
        #expect(loads.value == 0)
    }

    /// Scheitert das Lesen der App-Erweiterungen, behalten die Einträge ihre bisherige App.
    @Test func failingIndexKeepsPreviousOwners() async throws {
        let owner = ExtensionOwnership.app(path: Self.vendorApp.path, evidence: .bundleID)
        let previousRecords = try await source().collect().extensions.records.map { record in
            var record = record
            record.owner = owner
            return record
        }
        let previous = TestData.extensionSnapshot(previousRecords, apps: [Self.vendorApp])
        let extensions = source(index: { _ in throw ExtensionReadError.unavailable("x") })
        let snapshot = try await Self.coordinator(extensions, apps: .success(InventoryContribution(installedApps: [Self.vendorApp])))
            .scan(previous: previous)
        #expect(snapshot.extensions.allSatisfy { $0.owner == owner })
    }

    /// Ein Teilscan anderer Quellen (Lauscher im Minutentakt) liest keine App-Ordner.
    @Test func partialScanOfOtherSourcesDoesNotLoadTheIndex() async throws {
        let loads = IndexLoads()
        let extensions = source(index: { apps in
            loads.record()
            return AppExtensionIndex(apps: apps, embedded: [:], unreadable: [])
        })
        let coordinator = ScanCoordinator(sources: [
            FixedSource(id: .apps, result: .success(InventoryContribution(installedApps: [Self.vendorApp]))), extensions,
            FixedSource(id: .networkListeners, result: .success(InventoryContribution())),
        ], now: { TestData.date })
        let full = try await coordinator.scan()
        #expect(loads.value == 1)
        let partial = try await coordinator.scan(previous: full, only: [.networkListeners])
        #expect(loads.value == 1)
        #expect(partial.extensions == full.extensions)
    }

    // MARK: Beobachtung

    @Test func watchedDirectoriesAreTheExtensionAndPluginFolders() {
        #expect(ExtensionInventorySource.watchedDirectories(home: "/Users/test") == [
            "/Library/Extensions", "/Library/Audio/Plug-Ins/HAL", "/Users/test/Library/Audio/Plug-Ins/HAL",
            "/Library/CoreMediaIO/Plug-Ins/DAL",
        ])
        #expect(ExtensionInventorySource.watchedFiles == ["/Library/SystemExtensions/db.plist"])
    }
}
