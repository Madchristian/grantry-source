import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Rohwerte des Steckbriefs ohne Systemzugriff; zählt die Abrufe der Seriennummer.
final class FakeMacFacts: MacFactsReading {
    struct Values: Sendable {
        var modelIdentifier: String?
        var productName: String?
        var firmwareVersion: String?
        var systemVersionPlist: Data?
        var bootTime: Date?
        var wakeReason: String?
        var serialNumber: String?
    }

    private let values: Values
    private let counts = Mutex((reads: 0, serial: 0))

    init(_ values: Values) {
        self.values = values
    }

    var readCount: Int { counts.withLock { $0.reads } }
    var serialCount: Int { counts.withLock { $0.serial } }

    func modelIdentifier() -> String? {
        counts.withLock { $0.reads += 1 }
        return values.modelIdentifier
    }

    func productName() -> String? { values.productName }
    func firmwareVersion() -> String? { values.firmwareVersion }
    func systemVersionPlist() -> Data? { values.systemVersionPlist }
    func bootTime() -> Date? { values.bootTime }
    func wakeReason() -> String? { values.wakeReason }

    func serialNumber() -> String? {
        counts.withLock { $0.serial += 1 }
        return values.serialNumber
    }
}

@Suite struct MacProfileTests {
    static let serial = "C02XK0ZZJGH5"
    static let boot = Date(timeIntervalSince1970: 1_793_062_525)
    static let hardwareCommand = "/usr/sbin/system_profiler -detailLevel mini -json SPHardwareDataType"

    static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext,
                                                 subdirectory: "Fixtures/MacProfile"))
        return try Data(contentsOf: url)
    }

    static func chip(_ name: String? = "Apple M4 Max", memory: UInt64? = 64 << 30) -> ChipProfile {
        ChipProfile(facts: ChipFacts(brand: name, memoryBytes: memory))
    }

    static func fullFacts() throws -> FakeMacFacts.Values {
        FakeMacFacts.Values(
            modelIdentifier: "Mac16,6", productName: "MacBook Pro (14-inch, Nov 2024)",
            firmwareVersion: "mBoot-20457.41.3", systemVersionPlist: try fixture("systemversion-27.2", "plist"),
            bootTime: boot, wakeReason: "AOP.Outbox0_NotEmpty voice_trigger", serialNumber: serial
        )
    }

    static func source(_ facts: FakeMacFacts, runner: MockCommandRunner = MockCommandRunner(),
                       chip: ChipProfile = chip()) -> MacProfileSource {
        MacProfileSource(facts: facts, chip: { chip }, runner: runner)
    }

    // MARK: - Quelle

    @Test func readsAllValuesFromFacts() async throws {
        let runner = MockCommandRunner()
        let profile = await Self.source(FakeMacFacts(try Self.fullFacts()), runner: runner).profile()
        #expect(profile.name == "MacBook Pro (14-inch, Nov 2024)")
        #expect(profile.modelIdentifier == "Mac16,6")
        #expect(profile.chip == "Apple M4 Max")
        #expect(profile.memoryBytes == 64 << 30)
        #expect(profile.firmware == "20457.41.3")
        #expect(profile.system == MacProfile.OperatingSystem(name: "macOS", version: "27.2", build: "26B123",
                                                             securityResponse: nil))
        #expect(profile.bootTime == Self.boot)
        #expect(profile.lastWakeReason == "AOP.Outbox0_NotEmpty voice_trigger")
        #expect(runner.calls.isEmpty, "Mit Name und Firmware aus der IORegistry kein system_profiler")
    }

    @Test func readsOnceAndBuffers() async throws {
        let facts = FakeMacFacts(try Self.fullFacts())
        let source = Self.source(facts)
        async let first = source.profile()
        async let second = source.profile()
        #expect(await first == second)
        _ = await source.profile()
        #expect(facts.readCount == 1)
    }

    @Test func fallsBackToSystemProfilerWithoutRegistryName() async throws {
        var values = try Self.fullFacts()
        values.productName = nil
        values.firmwareVersion = nil
        let runner = MockCommandRunner()
        runner.stub(Self.hardwareCommand, CommandResult(
            exitCode: 0, stdout: String(decoding: try Self.fixture("sphardware-mini-intel", "json"), as: UTF8.self)
        ))
        let profile = await Self.source(FakeMacFacts(values), runner: runner).profile()
        #expect(profile.name == "MacBook Pro")
        #expect(profile.firmware == "2022.100.22.0.0 (iBridge: 21.16.4222.0.0,0)")
        #expect(runner.calls == [Self.hardwareCommand])
    }

    @Test func failingFallbackLeavesValuesMissing() async throws {
        var values = try Self.fullFacts()
        values.productName = nil
        let runner = MockCommandRunner()
        runner.stub(Self.hardwareCommand, CommandResult(exitCode: 1, stdout: "", stderr: "kaputt"))
        let profile = await Self.source(FakeMacFacts(values), runner: runner).profile()
        #expect(profile.name == nil)
        #expect(profile.firmware == "20457.41.3")
    }

    @Test func missingValuesShowDash() async {
        let profile = await Self.source(FakeMacFacts(FakeMacFacts.Values()), chip: Self.chip(nil, memory: nil))
            .profile()
        #expect(profile == MacProfile())
        let texts = [profile.nameText, profile.modelText, profile.chipText, profile.memoryText, profile.firmwareText,
                     profile.systemText, profile.uptimeText(at: Self.boot), profile.wakeReasonText]
        #expect(texts.allSatisfy { $0 == "–" })
    }

    @Test func formatsPresentValues() async throws {
        let profile = await Self.source(FakeMacFacts(try Self.fullFacts())).profile()
        #expect(profile.nameText == "MacBook Pro (14-inch, Nov 2024)")
        #expect(profile.modelText == "Mac16,6")
        #expect(profile.memoryText == ProcessCleanupPresentation.memoryText(64 << 30))
        #expect(profile.systemText == "macOS 27.2 (26B123)")
        #expect(profile.uptimeText(at: Self.boot.addingTimeInterval(86_400 + 3_600 + 61)) == "1:01:01:01")
        #expect(profile.uptimeText(at: Self.boot.addingTimeInterval(-10)) == "0:00:00:00")
    }

    @Test func foreignTextsBecomeSingleBoundedLines() async throws {
        var values = try Self.fullFacts()
        values.productName = "Mac\u{202E}Book\nPro"
        values.wakeReason = String(repeating: "x", count: 1_000)
        let profile = await Self.source(FakeMacFacts(values)).profile()
        #expect(profile.name == "MacBook Pro")
        #expect(profile.lastWakeReason?.count == MacProfile.maximumTextLength)
    }

    /// Abnahme 3: echte Quelle auf diesem Mac, nur lesend. Die Dauer des ersten Abrufs steht in der Testausgabe; die
    /// Grenze deckt nur Hänger ab (Zeitlimit von system_profiler plus Gnadenfrist plus Spielraum), keine
    /// Wanduhr-Vorgabe (#214). Der Spielraum deckt Prozessende und Planung unter Last: Auf dem CI-Runner lief
    /// system_profiler bis ins Zeitlimit und der Abruf endete nach 12,3 s, knapp über Zeitlimit plus Gnadenfrist.
    /// Opt-in wie die übrigen Live-Tests (`MANAGERKIT_LIVE=1`), nie in der CI: Ein hängender system_profiler belastete
    /// den Runner so, dass parallel laufende Tests mit Wanduhr-Fenstern kippten.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANAGERKIT_LIVE"] == "1"))
    func realSourceReadsThisMac() async {
        let source = MacProfileSource()
        let clock = ContinuousClock()
        let start = clock.now
        let profile = await source.profile()
        let first = clock.now - start
        let again = clock.now
        _ = await source.profile()
        print("MacProfileSource: erster Abruf \(first), gepuffert \(clock.now - again)")
        #expect(profile.modelIdentifier != nil)
        #expect(profile.system?.version != nil)
        #expect(profile.bootTime != nil)
        #expect(first < MacProfileSource.hardwareTimeout + ProcessCommandRunner.defaultTerminationGracePeriod
            + .seconds(3))
    }

    // MARK: - Parser

    @Test func parsesSecurityResponse() throws {
        let system = MacProfile.OperatingSystem(plist: try Self.fixture("systemversion-rsr", "plist"))
        #expect(system == MacProfile.OperatingSystem(name: "macOS", version: "13.3.1", build: "22E772610a",
                                                     securityResponse: "(a)"))
        #expect(MacProfile(system: system).systemText == "macOS 13.3.1 (a) (22E772610a)")
    }

    @Test func rejectsBrokenSystemVersion() {
        #expect(MacProfile.OperatingSystem(plist: Data("kein plist".utf8)) == nil)
        #expect(MacProfile.OperatingSystem(plist: Data()) == nil)
    }

    @Test func parsesRealHardwareOverview() throws {
        let overview = try #require(MacProfileSource.hardwareOverview(try Self.fixture("sphardware-mini-m4max", "json")))
        #expect(overview.name == "MacBook Pro")
        #expect(overview.firmware == "20457.41.3")
        #expect(MacProfileSource.hardwareOverview(Data("{}".utf8)) == nil)
        #expect(MacProfileSource.hardwareOverview(Data("[".utf8)) == nil)
    }

    @Test func stripsBootLoaderPrefixFromFirmware() {
        #expect(MacProfileSource.firmware("mBoot-20457.41.3") == "20457.41.3")
        #expect(MacProfileSource.firmware("iBoot-11881.1.1") == "11881.1.1")
        #expect(MacProfileSource.firmware("2022.100.22.0.0") == "2022.100.22.0.0")
        #expect(MacProfileSource.firmware("") == nil)
    }

    // MARK: - Seriennummer

    @Test func serialNumberOnlyOnDemandAndNeverBuffered() async throws {
        let facts = FakeMacFacts(try Self.fullFacts())
        let source = Self.source(facts)
        _ = await source.profile()
        #expect(facts.serialCount == 0, "Der Steckbrief liest die Seriennummer nicht mit")
        let serial = try #require(await source.serialNumber())
        #expect(serial.reveal() == Self.serial)
        _ = await source.serialNumber()
        #expect(facts.serialCount == 2, "Jeder Abruf liest neu, nichts wird gepuffert")
    }

    @Test func serialNumberMissingIsNil() async {
        #expect(await Self.source(FakeMacFacts(FakeMacFacts.Values())).serialNumber() == nil)
        #expect(MacSerialNumber("  \n") == nil)
    }

    /// Abnahme 2: Die Seriennummer steckt in keinem Codable-Wert und erscheint in keiner Text-, Debug- oder
    /// Log-Ausgabe (Logger und Interpolation nutzen `description`).
    @Test func serialNumberLeavesNoTrace() async throws {
        let source = Self.source(FakeMacFacts(try Self.fullFacts()))
        let serial = try #require(await source.serialNumber())
        let profile = await source.profile()

        #expect(!((serial as Any) is any Encodable))
        #expect(!((serial as Any) is any Decodable))
        #expect(!((profile as Any) is any Encodable))

        var dumped = ""
        dump(serial, to: &dumped)
        dump(profile, to: &dumped)
        let outputs = [String(describing: serial), String(reflecting: serial), "\(serial)", dumped,
                       String(describing: profile), String(reflecting: profile),
                       String(describing: Mirror(reflecting: serial).children.map(\.value))]
        for output in outputs {
            #expect(!output.contains(Self.serial), "Seriennummer sichtbar in: \(output)")
        }
        #expect(String(describing: serial) == MacSerialNumber.hiddenText)
    }
}
