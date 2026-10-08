import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite(.timeLimit(.minutes(1))) struct HostNameResolverTests {
    private let time = MutableInstant()

    /// Zeitlimit, das in diesen Tests nie abläuft: Der Timer wartet, bis die Abfrage ihn abbricht.
    private static let neverFires: @Sendable (Duration) async throws -> Void = { _ in try await Gate().wait() }

    private func resolver(_ dns: FakeReverseDNS, sleep: @escaping @Sendable (Duration) async throws -> Void = neverFires)
        -> HostNameResolver {
        HostNameResolver(lookup: dns, now: { [time] in time.now }, sleep: sleep)
    }

    @Test func cachesNamesForTenMinutes() async {
        let dns = FakeReverseDNS(["192.0.2.10": "api.example.com"])
        let resolver = resolver(dns)
        #expect(await resolver.resolve("192.0.2.10") == "api.example.com")
        #expect(await resolver.resolve("192.0.2.10") == "api.example.com")
        #expect(!resolver.needsLookup("192.0.2.10"))
        time.advance(by: .seconds(599))
        #expect(resolver.cachedName(for: "192.0.2.10") == "api.example.com")
        time.advance(by: .seconds(2))
        #expect(resolver.cachedName(for: "192.0.2.10") == nil)
        #expect(resolver.needsLookup("192.0.2.10"))
        #expect(dns.lookedUp == ["192.0.2.10"])
    }

    @Test func remembersMissingNamesForTwoMinutes() async {
        let dns = FakeReverseDNS([:])
        let resolver = resolver(dns)
        #expect(await resolver.resolve("2001:db8::1") == nil)
        time.advance(by: .seconds(119))
        #expect(!resolver.needsLookup("2001:db8::1"))
        #expect(await resolver.resolve("2001:db8::1") == nil)
        time.advance(by: .seconds(2))
        #expect(resolver.needsLookup("2001:db8::1"))
        #expect(dns.lookedUp == ["2001:db8::1"])
    }

    /// Nach dem Zeitlimit bleibt die IP stehen (`nil`); der späte Name wird nachgetragen.
    @Test func timesOutWithoutWaitingForSlowLookup() async throws {
        let gate = Gate()
        let dns = FakeReverseDNS(["192.0.2.10": "api.example.com"], gate: gate)
        let resolver = resolver(dns, sleep: { _ in })
        #expect(await resolver.resolve("192.0.2.10") == nil)
        #expect(!resolver.needsLookup("192.0.2.10"))
        gate.open()
        while resolver.cachedName(for: "192.0.2.10") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dns.lookedUp == ["192.0.2.10"])
    }

    @Test func limitsConcurrentLookups() async {
        let gate = Gate()
        let dns = FakeReverseDNS([:], gate: gate)
        let resolver = resolver(dns)
        let tasks = (1...4).map { index in Task { await resolver.resolve("192.0.2.\(index)") } }
        for await _ in dns.calls.prefix(4) {}

        #expect(await resolver.resolve("192.0.2.5") == nil)
        #expect(!resolver.needsLookup("192.0.2.5"))
        #expect(dns.lookedUp.count == 4)

        for _ in tasks { gate.open() }
        for task in tasks { _ = await task.value }
        #expect(resolver.needsLookup("192.0.2.5"))
    }

    /// Ein abgebrochener Aufrufer wartet nicht auf die Abfrage; ihr spätes Ergebnis landet trotzdem im Cache.
    @Test func cancelledResolveReturnsAtOnceAndStillCachesName() async throws {
        let gate = Gate()
        let dns = FakeReverseDNS(["192.0.2.10": "api.example.com"], gate: gate)
        let resolver = resolver(dns)
        let task = Task { await resolver.resolve("192.0.2.10") }
        for await _ in dns.calls.prefix(1) {}
        task.cancel()
        #expect(await task.value == nil)

        gate.open()
        while resolver.cachedName(for: "192.0.2.10") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Über der Schwelle räumt der Resolver abgelaufene Einträge aus; gültige bleiben.
    @Test func prunesExpiredEntriesAboveThreshold() async {
        let dns = FakeReverseDNS(["192.0.2.3": "c.example.com"])
        let resolver = HostNameResolver(lookup: dns, cachePruneThreshold: 2, now: { [time] in time.now },
                                        sleep: Self.neverFires)
        _ = await resolver.resolve("192.0.2.1")
        _ = await resolver.resolve("192.0.2.2")
        _ = await resolver.resolve("192.0.2.3")
        #expect(resolver.cacheCount == 3)
        time.advance(by: .seconds(121))
        _ = await resolver.resolve("192.0.2.4")
        #expect(resolver.cacheCount == 2)
        #expect(resolver.cachedName(for: "192.0.2.3") == "c.example.com")
    }

    @Test func skipsLocalAndPrivateAddresses() async {
        let dns = FakeReverseDNS([:])
        let resolver = resolver(dns)
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.5", "100.64.0.1", "169.254.1.1", "::1",
                        "fe80::1%en0", "fd00::1", "ff02::fb", "224.0.0.251", "*"] {
            #expect(await resolver.resolve(address) == nil, "\(address)")
            #expect(!resolver.needsLookup(address), "\(address)")
        }
        #expect(dns.lookedUp.isEmpty)
    }

    @Test func classifiesAddressScopes() {
        #expect(IPAddressScope.isPublic("192.0.2.10"))
        #expect(IPAddressScope.isPublic("2001:db8::1"))
        #expect(IPAddressScope.isPublic("::ffff:192.0.2.10"))
        #expect(!IPAddressScope.isPublic("::ffff:192.168.0.1"))
        #expect(!IPAddressScope.isPublic("::"))
        #expect(!IPAddressScope.isPublic("0.0.0.0"))
        #expect(!IPAddressScope.isPublic("kein-host"))
    }

    @Test func classifiesRangeBoundaries() {
        #expect(IPAddressScope.isPublic("172.32.0.1"))
        #expect(!IPAddressScope.isPublic("172.31.255.255"))
        #expect(IPAddressScope.isPublic("100.128.0.1"))
        #expect(!IPAddressScope.isPublic("100.127.255.255"))
        #expect(!IPAddressScope.isPublic("255.255.255.255"))
        #expect(!IPAddressScope.isPublic("::ffff:10.0.0.1"))
    }

    /// NAT64 (`64:ff9b::/96`) trägt die IPv4-Adresse in den letzten 32 Bit.
    @Test func mapsNAT64ToEmbeddedIPv4() {
        #expect(IPAddressScope.isPublic("64:ff9b::192.0.2.10"))
        #expect(!IPAddressScope.isPublic("64:ff9b::10.0.0.1"))
        #expect(!IPAddressScope.isPublic("64:ff9b::127.0.0.1"))
    }

    @Test func locationSeparatesThisMacLocalNetworkAndInternet() {
        #expect(IPAddressScope.location(of: "127.0.0.1") == .thisMac)
        #expect(IPAddressScope.location(of: "::1") == .thisMac)
        #expect(IPAddressScope.location(of: "192.168.1.20") == .localNetwork)
        #expect(IPAddressScope.location(of: "fe80::1%en0") == .localNetwork)
        #expect(IPAddressScope.location(of: "192.0.2.10") == .internet)
    }
}
