import Testing
import Foundation
@testable import ManagerKit

/// Opt-in-Tests gegen das echte System; laufen nur mit `MANAGERKIT_LIVE=1`, weil das Ergebnis vom Rechner abhängt.
/// BTM fehlt bewusst: `sfltool dumpbtm` braucht den privilegierten Helper.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"))
struct LiveSystemTests {
    @Test func launchdSourceReadsRealAgents() async throws {
        let source = LaunchdSource(runner: ProcessCommandRunner(), resolver: AppResolver())
        let items = try await source.collect().autostartItems
        #expect(!items.isEmpty)
        print("launchd items=\(items.count)")
        for item in items.prefix(10) {
            print("\(item.kind) \(item.domain) \(item.label) enabled=\(item.isEnabled) loaded=\(String(describing: item.isLoaded)) owner=\(item.owner?.displayName ?? "-")")
        }
    }

    /// Die System-Datenbank muss mit Festplattenvollzugriff Grants liefern; ohne ihn (Terminal) scheitert sie mit
    /// `.cannotOpen`. Die Benutzer-Datenbank existiert unter macOS 27 nicht mehr und darf scheitern. v1 scannt sie
    /// nicht (`includeUserDatabase: false` ist der Produktivstandard); hier wird sie zusätzlich angefordert, um die
    /// Ausfallisolation gegenüber der System-DB weiter live abzudecken.
    @Test func tccSourcesReadSystemGrantsIndependentlyOfUserDatabase() async throws {
        var systemError: (any Error)?
        var systemGrants = 0
        for source in TCCSource.standard(resolver: AppResolver(), includeUserDatabase: true) {
            do {
                let grants = try await source.collect().grants
                print("\(source.id): grants=\(grants.count)")
                if source.id == .tccSystem { systemGrants = grants.count }
            } catch {
                print("\(source.id): error=\(error)")
                if source.id == .tccSystem { systemError = error }
            }
        }
        let systemCannotOpen = if case .cannotOpen? = systemError as? TCCReadError { true } else { false }
        #expect(systemGrants > 0 || systemCannotOpen)
    }

    /// Dauer eines echten Inventar-Scans (rein lesend): erster Lauf ohne Cache, zweiter mit Signatur-Cache.
    @Test func appInventoryReadsRealApps() async throws {
        let source = AppInventorySource()
        let clock = ContinuousClock()
        var apps: [InstalledApp] = []
        let first = try await clock.measure { apps = try await source.collect().installedApps }
        let second = try await clock.measure { _ = try await source.collect() }
        print("apps=\(apps.count) first=\(first) second=\(second)")
        for app in apps.prefix(10) {
            print("\(app.name) \(app.versionText ?? "-") \(app.origin) \(app.signing.kind) \(app.architecture)")
        }
        #expect(!apps.isEmpty)
    }

    /// Dauer der Hintergrund-Anreicherung (Größe, zuletzt benutzt) für alle Apps, rein lesend; zweiter Lauf aus dem Cache.
    @Test func appDetailsForRealApps() async throws {
        let apps = try await AppInventorySource().collect().installedApps
        let loader = AppDetailsLoader()
        let clock = ContinuousClock()
        var details: [AppUsageDetails] = []
        let first = await clock.measure { for app in apps { details.append(await loader.details(for: app.path)) } }
        let second = await clock.measure { for app in apps { _ = await loader.details(for: app.path) } }
        let total = details.compactMap(\.size).reduce(0, +)
        print("apps=\(apps.count) sizes=\(details.compactMap(\.size).count) lastUsed=\(details.compactMap(\.lastUsed).count) "
              + "total=\(total / 1_000_000) MB first=\(first) second=\(second)")
        #expect(details.contains { $0.size != nil })
    }
}
