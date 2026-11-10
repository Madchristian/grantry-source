import Foundation
import GrantryShared
import Synchronization

/// Quelle des Steckbriefs (Dieser Mac, TM16): liest einmal je App-Start und puffert das Ergebnis; kein Takt.
///
/// sysctl, IORegistry und `SystemVersion.plist` laufen auf einer eigenen Queue mit QoS `utility`. Fehlen Name oder
/// Firmware im Gerätebaum (Intel, virtuelle Maschinen), fragt sie einmal `system_profiler` mit Zeitlimit; dessen
/// Detailstufe `mini` lässt Seriennummer und UUIDs weg. Die Seriennummer liest nur `serialNumber()` – bei jedem Abruf
/// neu, nie gepuffert und nie Teil von `MacProfile`.
public final class MacProfileSource: Sendable {
    /// Für die App: ein Steckbrief je Start.
    public static let shared = MacProfileSource()

    static let systemProfiler = "/usr/sbin/system_profiler"
    static let hardwareArguments = ["-detailLevel", "mini", "-json", "SPHardwareDataType"]
    static let hardwareTimeout: Duration = .seconds(10)
    static let maximumHardwareOutput = 64 * 1024

    private let facts: any MacFactsReading
    private let chip: @Sendable () -> ChipProfile
    private let runner: any CommandRunning
    private let workQueue = BlockingWorkQueue(label: "mac-profile")
    private let loading = Mutex<Task<MacProfile, Never>?>(nil)

    public convenience init() {
        self.init(facts: SystemMacFacts(), chip: { ChipProfile.current }, runner: ProcessCommandRunner())
    }

    init(facts: any MacFactsReading, chip: @escaping @Sendable () -> ChipProfile, runner: any CommandRunning) {
        self.facts = facts
        self.chip = chip
        self.runner = runner
    }

    /// Der Steckbrief; der erste Aufruf liest, alle weiteren (auch gleichzeitige) erhalten dasselbe Ergebnis.
    public func profile() async -> MacProfile {
        let task = loading.withLock { task in
            if let task { return task }
            let started = Task { await load() }
            task = started
            return started
        }
        return await task.value
    }

    /// Die Seriennummer auf Abruf („Einblenden“); `nil`, wenn nicht lesbar.
    public func serialNumber() async -> MacSerialNumber? {
        await workQueue.run { [facts] in facts.serialNumber().flatMap(MacSerialNumber.init) }
    }

    private func load() async -> MacProfile {
        var profile = await workQueue.run { [facts, chip] in
            let chip = chip()
            return MacProfile(
                name: facts.productName().flatMap(MacProfile.cleaned),
                modelIdentifier: facts.modelIdentifier().flatMap(MacProfile.cleaned),
                chip: chip.name.flatMap(MacProfile.cleaned), memoryBytes: chip.memoryBytes,
                firmware: facts.firmwareVersion().flatMap(Self.firmware),
                system: facts.systemVersionPlist().flatMap(MacProfile.OperatingSystem.init(plist:)),
                bootTime: facts.bootTime(), lastWakeReason: facts.wakeReason().flatMap(MacProfile.cleaned)
            )
        }
        if profile.name == nil || profile.firmware == nil, let overview = await hardwareOverview() {
            profile.name = profile.name ?? overview.name
            profile.firmware = profile.firmware ?? overview.firmware
        }
        return profile
    }

    /// Name und Firmware laut `system_profiler`; `nil` bei Fehler, Zeitüberschreitung oder unlesbarer Ausgabe.
    private func hardwareOverview() async -> (name: String?, firmware: String?)? {
        guard let result = try? await runner.run(Self.systemProfiler, Self.hardwareArguments,
                                                 timeout: Self.hardwareTimeout,
                                                 outputLimit: Self.maximumHardwareOutput),
              result.succeeded else { return nil }
        return Self.hardwareOverview(Data(result.stdout.utf8))
    }

    /// Liest `machine_name` und `boot_rom_version` aus `system_profiler -json SPHardwareDataType`; andere Felder
    /// bleiben unbeachtet.
    static func hardwareOverview(_ data: Data) -> (name: String?, firmware: String?)? {
        struct Output: Decodable {
            struct Hardware: Decodable {
                let machineName: String?
                let bootROMVersion: String?

                enum CodingKeys: String, CodingKey {
                    case machineName = "machine_name"
                    case bootROMVersion = "boot_rom_version"
                }
            }

            let hardware: [Hardware]

            enum CodingKeys: String, CodingKey {
                case hardware = "SPHardwareDataType"
            }
        }
        guard let hardware = (try? JSONDecoder().decode(Output.self, from: data))?.hardware.first else { return nil }
        return (hardware.machineName.flatMap(MacProfile.cleaned), hardware.bootROMVersion.flatMap(firmware))
    }

    /// Firmware ohne Ladernamen: „mBoot-20457.41.3“ → „20457.41.3“.
    static func firmware(_ raw: String) -> String? {
        guard let text = MacProfile.cleaned(raw) else { return nil }
        guard let dash = text.firstIndex(of: "-"), text[..<dash].hasSuffix("Boot") else { return text }
        return MacProfile.cleaned(String(text[text.index(after: dash)...]))
    }
}
