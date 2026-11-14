import Foundation
import os
import Testing
@testable import ManagerKit

/// Ländertabelle (#630): Zugriff auf die mit `scripts/country_table.py` gebaute Datei. Die Fixture stammt aus
/// `Fixtures/CountryTable/ipv4.txt` und `ipv6.txt` (CSV-Zeilen) (`scripts/tests/test_country_table.py` hält beide zusammen).
@Suite struct CountryTableTests {
    static func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "CountryTable", withExtension: "bin",
                                       subdirectory: "Fixtures/CountryTable"))
    }

    private func table() throws -> CountryTable { try CountryTable(contentsOf: Self.fixtureURL()) }

    @Test(arguments: [
        ("1.0.0.0", "AU"), ("1.0.0.255", "AU"), ("1.0.1.0", "CN"), ("1.0.3.255", "CN"), ("8.8.8.8", "US"),
        ("192.0.2.0", "DE"), ("192.0.2.255", "DE"), ("223.255.255.0", "AU"), ("223.255.255.255", "AU"),
    ])
    func findsTheCountryAtBothEndsOfAnIPv4Range(_ address: String, _ code: String) throws {
        #expect(try table().countryCode(for: address) == code)
    }

    @Test(arguments: ["0.0.0.0", "0.255.255.255", "1.0.4.0", "8.8.7.255", "8.8.9.0", "192.0.1.255", "192.0.3.0",
                      "223.255.254.255", "224.0.0.0", "255.255.255.255"])
    func ipv4AddressesOutsideEveryRangeHaveNoEntry(_ address: String) throws {
        #expect(try table().countryCode(for: address) == nil)
    }

    @Test(arguments: [
        ("2001:db8::", "NL"), ("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", "NL"), ("2001:db8::1%en0", "NL"),
        ("2a00::", "SE"), ("2a00:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "SE"),
        // Nur ein Teil des /64 ist vergeben, an genau ein Land: es gilt für das ganze /64.
        ("2001:db9::1", "FR"), ("2001:db9::ffff:0:0:1", "FR"),
    ])
    func findsTheCountryAtBothEndsOfAnIPv6Range(_ address: String, _ code: String) throws {
        #expect(try table().countryCode(for: address) == code)
    }

    @Test(arguments: ["::", "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db9:0:1::", "29ff:ffff:ffff:ffff::",
                      "2a01::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
                      // Dieses /64 teilen sich zwei Länder: kein Eintrag statt eines geratenen.
                      "2001:dba::1", "2001:dba::8000:0:0:1"])
    func ipv6AddressesWithoutAnUnambiguousRangeHaveNoEntry(_ address: String) throws {
        #expect(try table().countryCode(for: address) == nil)
    }

    @Test func resolvesIPv4MappedAndNAT64ThroughTheEmbeddedAddress() throws {
        #expect(try table().countryCode(for: "::ffff:192.0.2.10") == "DE")
        #expect(try table().countryCode(for: "64:ff9b::192.0.2.10") == "DE")
        #expect(try table().countryCode(for: "::ffff:192.0.3.1") == nil)
    }

    @Test(arguments: ["", "*", "kein-host", "example.com", "192.0.2", "192.0.2.256", "2001:db8::g"])
    func textThatIsNoAddressHasNoEntry(_ text: String) throws {
        #expect(try table().countryCode(for: text) == nil)
    }

    @Test func carriesTheDateOfTheData() throws {
        #expect(try table().dataDate == DateComponents(year: 2026, month: 11, day: 13))
    }

    @Test func reportsAMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        #expect(throws: CountryTable.LoadError.unreadable) { try CountryTable(contentsOf: missing) }
    }

    @Test func rejectsTruncatedForeignAndInconsistentData() throws {
        let data = try Data(contentsOf: Self.fixtureURL())
        var foreign = data
        foreign[0] = 0x58
        var withoutLeadingSegment = data
        // Erster IPv4-Beginn (hinter Kopf und Ländercodes) ungleich 0: Adressen davor hätten keinen Abschnitt.
        withoutLeadingSegment[32 + 24] = 1
        for broken in [Data(), data.prefix(16), data.dropLast(8), data + Data(count: 8), foreign,
                       withoutLeadingSegment] {
            #expect(throws: CountryTable.LoadError.malformed) { try CountryTable(data: Data(broken)) }
        }
    }

    /// Die ausgelieferte Tabelle aus Grantry/GeoData lässt sich öffnen und kennt lange stabile Adressblöcke; private
    /// und lokale Adressen stehen in keinem Land.
    @Test func opensTheShippedTable() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../Grantry/GeoData/CountryTable.bin").standardized
        let table = try CountryTable(contentsOf: url)
        #expect(table.countryCode(for: "8.8.8.8") == "US")
        #expect(table.countryCode(for: "193.0.14.129") == "NL")
        #expect(table.countryCode(for: "2001:4860:4860::8888") != nil)
        for local in ["10.0.0.1", "172.16.0.1", "192.168.1.1", "100.64.0.1", "169.254.1.1", "127.0.0.1", "::1",
                      "fe80::1", "fd00::1"] {
            #expect(table.countryCode(for: local) == nil, "\(local)")
        }
        let year = try #require(table.dataDate.year)
        #expect(year >= 2026)
    }
}

/// Zuordnung der Gegenstellen: private und lokale Adressen bekommen nie ein Land, auch wenn eine Tabelle eines nennt.
@Suite struct RemoteRegionResolverTests {
    private func resolver() throws -> RemoteRegionResolver {
        RemoteRegionResolver(table: try CountryTable(contentsOf: CountryTableTests.fixtureURL()))
    }

    @Test func publicAddressesGetTheCountryOfTheirBlock() throws {
        let resolver = try resolver()
        #expect(resolver.region(of: "192.0.2.10") == .country("DE"))
        #expect(resolver.region(of: "2001:db8::44") == .country("NL"))
        #expect(resolver.region(of: "::ffff:198.51.100.7") == .country("US"))
    }

    @Test func publicAddressesWithoutAnEntryAreUnknown() throws {
        let resolver = try resolver()
        #expect(resolver.region(of: "9.9.9.9") == .unknown)
        #expect(resolver.region(of: "2001:dba::1") == .unknown)
        #expect(resolver.region(of: "kein-host") == .unknown)
    }

    @Test(arguments: ["127.0.0.1", "::1", "::ffff:127.0.0.1"])
    func loopbackIsThisMac(_ address: String) throws {
        #expect(try resolver().region(of: address) == .thisMac)
    }

    @Test(arguments: ["10.0.0.1", "172.16.0.1", "192.168.1.20", "100.64.0.1", "169.254.1.1", "fe80::1%en0", "fd00::24",
                      "224.0.0.251", "ff02::fb", "::ffff:192.168.1.1"])
    func privateAndLocalAddressesAreTheLocalNetwork(_ address: String) throws {
        #expect(try resolver().region(of: address) == .localNetwork)
    }

    /// Selbst eine Tabelle, die für alles ein Land nennt, wird für lokale Adressen nicht gefragt.
    @Test func neverAsksTheTableForLocalAddresses() {
        let asked = LockedList()
        let resolver = RemoteRegionResolver(dataDate: nil) { asked.append($0); return "XX" }
        #expect(resolver.region(of: "192.168.1.1") == .localNetwork)
        #expect(resolver.region(of: "127.0.0.1") == .thisMac)
        #expect(resolver.region(of: "192.0.2.1") == .country("XX"))
        #expect(asked.values == ["192.0.2.1"])
    }

    @Test func looksEachAddressUpOnce() {
        let asked = LockedList()
        let resolver = RemoteRegionResolver(dataDate: nil) { asked.append($0); return "DE" }
        for _ in 0..<3 {
            #expect(resolver.region(of: "192.0.2.1") == .country("DE"))
            #expect(resolver.region(of: "192.0.2.2") == .country("DE"))
        }
        #expect(asked.values == ["192.0.2.1", "192.0.2.2"])
    }

    @Test func cacheStaysBounded() {
        let asked = LockedList()
        let resolver = RemoteRegionResolver(dataDate: nil) { asked.append($0); return "DE" }
        let addresses = (0...RemoteRegionResolver.cacheLimit).map { "192.0.\($0 / 256 + 2).\($0 % 256)" }
        addresses.forEach { _ = resolver.region(of: $0) }
        // Nach dem Neubeginn wird die erste Adresse erneut nachgeschlagen, die letzte nicht.
        _ = resolver.region(of: addresses[0])
        _ = resolver.region(of: addresses[addresses.count - 1])
        #expect(asked.values.count == addresses.count + 1)
    }

    @Test func withoutATableEverythingPublicIsUnknown() {
        #expect(RemoteRegionResolver.unavailable.region(of: "192.0.2.1") == .unknown)
        #expect(RemoteRegionResolver.unavailable.region(of: "192.168.1.1") == .localNetwork)
        #expect(RemoteRegionResolver.unavailable.dataDate == nil)
        #expect(RemoteRegionResolver(bundle: Bundle(for: LockedList.self)).dataDate == nil)
    }

    @Test func namesCountriesThroughTheSystemLocale() {
        #expect(RemoteRegion.country("DE").title(locale: Locale(identifier: "de_DE")) == "Deutschland")
        #expect(RemoteRegion.country("US").title(locale: Locale(identifier: "de_DE")) == "Vereinigte Staaten")
        #expect(RemoteRegion.country("DE").title(locale: Locale(identifier: "en_US")) == "Germany")
        #expect(RemoteRegion.unknown.title() == "Land unbekannt")
        #expect(RemoteRegion.localNetwork.title() == "Lokales Netz")
        #expect(RemoteRegion.thisMac.title() == "Dieser Mac")
    }
}

/// Mitschrift der Nachfragen an eine Test-Tabelle.
private final class LockedList: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())
    var values: [String] { storage.withLock { $0 } }
    func append(_ value: String) { storage.withLock { $0.append(value) } }
}
