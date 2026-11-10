import Darwin
import Dispatch
import Synchronization
import Testing
@testable import ManagerKit

@Suite struct InterfaceThroughputSamplerTests {
    private func message(index: UInt16, up: Bool, received: UInt64, sent: UInt64) -> [UInt8] {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = index
        header.ifm_flags = up ? IFF_UP : 0
        header.ifm_data.ifi_ibytes = received
        header.ifm_data.ifi_obytes = sent
        return withUnsafeBytes(of: header) { Array($0) }
    }

    /// Länge 8, Version 5, Typ `RTM_NEWADDR` – keine Schnittstellen-Nachricht.
    private let foreign: [UInt8] = [8, 0, 5, UInt8(RTM_NEWADDR), 0, 0, 0, 0]

    @Test func parsesInterfaceMessagesAndSkipsOthers() {
        let buffer = message(index: 1, up: true, received: 5_000_000_000, sent: 7) + foreign
            + message(index: 4, up: false, received: 1, sent: 2)
        #expect(InterfaceThroughputSampler.parse(buffer) == [
            .init(index: 1, isUp: true, bytesReceived: 5_000_000_000, bytesSent: 7),
            .init(index: 4, isUp: false, bytesReceived: 1, bytesSent: 2),
        ])
    }

    @Test func stopsAtTruncatedOrEmptyMessage() {
        let complete = message(index: 2, up: true, received: 1, sent: 1)
        #expect(InterfaceThroughputSampler.parse(complete + complete.prefix(20)).count == 1)
        #expect(InterfaceThroughputSampler.parse([0, 0, 5, 0] + complete).isEmpty)
    }

    @Test func readsLoopbackOfThisMac() throws {
        let interfaces = try InterfaceThroughputSampler().read()
        let loopback = try #require(interfaces.first { $0.name == "lo0" })
        #expect(loopback.addresses.contains("127.0.0.1"))
        #expect(Set(interfaces.map(\.name)).count == interfaces.count)
        #expect(interfaces.filter(\.isPrimary).count <= 1)
    }

    // MARK: Namen und Adressen aus einem getifaddrs-Durchlauf

    @Test func oneAddressPassNamesEveryInterface() throws {
        let table = try #require(InterfaceThroughputSampler.InterfaceTable.current())
        #expect(table.names[UInt16(if_nametoindex("lo0"))] == "lo0")
        #expect(table.addresses["lo0"]?.isEmpty == false)
    }

    /// Das Ergebnis muss dem alten Weg (`if_indextoname` je Schnittstelle) entsprechen: Dieselben Indizes tragen dieselben
    /// Namen. Eine Schnittstelle, die zwischen den Abfragen verschwindet, hat dort keinen Namen und zählt nicht.
    @Test func tableNamesMatchIfIndexToName() throws {
        let indices = InterfaceThroughputSampler.parse(try InterfaceThroughputSampler.routeBuffer()).map(\.index)
        let table = try #require(InterfaceThroughputSampler.InterfaceTable.current())
        var named = 0
        for index in indices {
            let name = withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(IF_NAMESIZE)) { buffer in
                if_indextoname(UInt32(index), buffer.baseAddress!).map { String(cString: $0) }
            }
            guard let name else { continue }
            #expect(table.names[index] == name)
            named += 1
        }
        #expect(named > 0)
    }

    @Test func formatsNumericAddresses() {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("192.168.7.42"))
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        #expect(InterfaceThroughputSampler.numericHost(bytes) == "192.168.7.42")
        #expect(InterfaceThroughputSampler.numericHost([0, 0]) == nil)
    }

    @Test func formatsAddressesOnlyAfterTheyChange() {
        var cache = InterfaceThroughputSampler.AddressCache()
        let calls = Recorder<[UInt8]>()
        let format: ([UInt8]) -> String? = { bytes in
            calls.append(bytes)
            return bytes.map(String.init).joined(separator: ".")
        }
        #expect(cache.addresses(for: ["en0": [[1, 2]]], format: format) == ["en0": ["1.2"]])
        #expect(cache.addresses(for: ["en0": [[1, 2]]], format: format) == ["en0": ["1.2"]])
        #expect(calls.values.count == 1)
        #expect(cache.addresses(for: ["en0": [[1, 3]]], format: format) == ["en0": ["1.3"]])
        #expect(calls.values.count == 2)
    }

    /// Eine unformatierbare Adresse fehlt im Ergebnis, die übrigen der Schnittstelle bleiben (wie bei `getnameinfo`).
    @Test func addressThatCannotBeFormattedIsSkipped() {
        var cache = InterfaceThroughputSampler.AddressCache()
        let result = cache.addresses(for: ["en0": [[1], [2]]]) { $0 == [1] ? nil : "two" }
        #expect(result == ["en0": ["two"]])
    }

    // MARK: Auflösung nur bei geänderter Schnittstellenliste

    /// Nachricht beliebigen Typs (Version 5) mit frei wählbarem Inhalt.
    private func raw(type: Int32, _ payload: [UInt8]) -> [UInt8] {
        [UInt8(payload.count + 4), 0, 5, UInt8(type)] + payload
    }

    /// Adresse einer Schnittstelle (`RTM_NEWADDR`); der Inhalt steht für die Adresse selbst.
    private func address(_ payload: [UInt8]) -> [UInt8] {
        raw(type: RTM_NEWADDR, payload)
    }

    @Test func unchangedListIsResolvedOnceWhileCountersStayCurrent() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        var results: [[InterfaceCounters]] = []
        for received: UInt64 in [100, 250, 900] {
            system.buffer = message(index: 1, up: true, received: received, sent: received / 10)
                + address([10, 0, 0, 1])
            results.append(try sampler.read())
        }
        #expect(system.resolutions == [[1]])
        #expect(results == [100, 250, 900].map { (received: UInt64) in
            [InterfaceCounters(name: "if1", bytesReceived: received, bytesSent: received / 10,
                               displayName: "Name 1", addresses: ["10.0.0.1"])]
        })
    }

    /// Bewertung 2026.11.7-1188, Mangel 4: Die Schnittstelle der Default-Route wird bei jeder Lesung neu erfragt,
    /// auch wenn sich die Schnittstellenliste nicht ändert.
    @Test func marksInterfaceOfDefaultRouteOnEveryRead() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        system.buffer = message(index: 1, up: true, received: 1, sent: 1) + message(index: 8, up: true, received: 1, sent: 1)
        system.primary = "if8"
        #expect(try sampler.read().map(\.isPrimary) == [false, true])
        system.primary = "if1"
        #expect(try sampler.read().map(\.isPrimary) == [true, false])
        system.primary = nil
        #expect(try sampler.read().map(\.isPrimary) == [false, false])
        #expect(system.resolutions.count == 1)
    }

    @Test func newInterfaceIsResolvedAgain() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        system.buffer = message(index: 1, up: true, received: 1, sent: 1)
        _ = try sampler.read()
        system.buffer = message(index: 1, up: true, received: 2, sent: 2) + message(index: 7, up: true, received: 3, sent: 3)
        let interfaces = try sampler.read()
        #expect(system.resolutions == [[1], [1, 7]])
        #expect(interfaces.map(\.name) == ["if1", "if7"])
        #expect(interfaces.map(\.displayName) == ["Name 2", "Name 2"])
    }

    @Test func interfaceChangingBetweenUpAndDownIsResolvedAgain() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        system.buffer = message(index: 1, up: true, received: 1, sent: 1) + message(index: 4, up: false, received: 1, sent: 1)
        #expect(try sampler.read().map(\.name) == ["if1"])
        system.buffer = message(index: 1, up: true, received: 2, sent: 2) + message(index: 4, up: true, received: 2, sent: 2)
        #expect(try sampler.read().map(\.name) == ["if1", "if4"])
        system.buffer = message(index: 1, up: false, received: 3, sent: 3) + message(index: 4, up: true, received: 3, sent: 3)
        #expect(try sampler.read().map(\.name) == ["if4"])
        #expect(system.resolutions == [[1], [1, 4], [4]])
    }

    @Test func changedAddressIsResolvedAgainButSameAddressIsNot() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        let up = message(index: 1, up: true, received: 1, sent: 1)
        system.buffer = up + address([10, 0, 0, 1])
        _ = try sampler.read()
        _ = try sampler.read()
        #expect(system.resolutions.count == 1)
        system.buffer = up + address([10, 0, 0, 2])
        _ = try sampler.read()
        system.buffer = up + address([10, 0, 0, 2]) + address([0xfe, 0x80, 0, 1])
        _ = try sampler.read()
        #expect(system.resolutions.count == 3)
    }

    @Test func multicastGroupsDoNotTriggerResolution() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        let up = message(index: 1, up: true, received: 1, sent: 1)
        system.buffer = up + raw(type: RTM_NEWMADDR2, [224, 0, 0, 251])
        _ = try sampler.read()
        system.buffer = up + raw(type: RTM_NEWMADDR2, [224, 0, 0, 251]) + raw(type: RTM_NEWMADDR2, [239, 255, 255, 250])
        _ = try sampler.read()
        #expect(system.resolutions == [[1]])
    }

    @Test func failedResolutionIsRetriedOnNextReadInsteadOfCached() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        system.buffer = message(index: 1, up: true, received: 1, sent: 1)
        system.failsResolution = true
        #expect(try sampler.read().isEmpty)
        system.failsResolution = false
        #expect(try sampler.read().map(\.name) == ["if1"])
        _ = try sampler.read()
        #expect(system.resolutions == [[1], [1]])
    }

    @Test func failedRouteReadThrowsAndKeepsResolvedNames() throws {
        let system = StubbedSystem()
        let sampler = system.sampler()
        system.buffer = message(index: 1, up: true, received: 1, sent: 1)
        _ = try sampler.read()
        system.failsRouteRead = true
        #expect(throws: InterfaceThroughputSampler.ReadFailure(code: ENOMEM)) { try sampler.read() }
        system.failsRouteRead = false
        #expect(try sampler.read().map(\.name) == ["if1"])
        #expect(system.resolutions == [[1]])
    }

    @Test func concurrentReadsResolveOnce() {
        let system = StubbedSystem()
        let sampler = system.sampler()
        system.buffer = message(index: 1, up: true, received: 1, sent: 1) + address([10, 0, 0, 1])
        let counts = Recorder<Int>()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            counts.append((try? sampler.read().count) ?? -1)
        }
        #expect(counts.values == Array(repeating: 1, count: 64))
        #expect(system.resolutions.count == 1)
    }

    /// Schützt die Zwischenspeicherung gegen Teile des echten Puffers, die sich ohne Änderung der Liste von Lesung zu
    /// Lesung unterscheiden würden: Dann löste jeder Takt neu auf.
    @Test func secondReadOfThisMacIsServedFromTheCache() throws {
        let resolutions = Recorder<[UInt16]>()
        let sampler = InterfaceThroughputSampler(readBuffer: InterfaceThroughputSampler.routeBuffer) { indices in
            resolutions.append(indices)
            return InterfaceThroughputSampler.systemIdentities(for: indices)
        }
        let first = try sampler.read()
        let second = try sampler.read()
        #expect(resolutions.values.count == 1)
        #expect(first.map(\.name) == second.map(\.name))
        #expect(first.map(\.addresses) == second.map(\.addresses))
        #expect(first.map(\.displayName) == second.map(\.displayName))
    }
}

/// Routing-Puffer und Auflösung des Systems, von außen steuerbar. Die Auflösung zählt mit und trägt ihre laufende
/// Nummer in den Anzeigenamen („Name 2“), damit man zwischengespeicherte von frisch aufgelösten Angaben unterscheidet.
private final class StubbedSystem: Sendable {
    private struct State {
        var buffer: [UInt8] = []
        var resolutions: [[UInt16]] = []
        var failsResolution = false
        var failsRouteRead = false
        var primary: String?
    }

    private let state = Mutex(State())

    var buffer: [UInt8] {
        get { state.withLock { $0.buffer } }
        set { state.withLock { $0.buffer = newValue } }
    }

    var failsResolution: Bool {
        get { state.withLock { $0.failsResolution } }
        set { state.withLock { $0.failsResolution = newValue } }
    }

    var failsRouteRead: Bool {
        get { state.withLock { $0.failsRouteRead } }
        set { state.withLock { $0.failsRouteRead = newValue } }
    }

    var primary: String? {
        get { state.withLock { $0.primary } }
        set { state.withLock { $0.primary = newValue } }
    }

    /// Die aktiven Indizes jeder Auflösung, in der Reihenfolge der Aufrufe.
    var resolutions: [[UInt16]] { state.withLock { $0.resolutions } }

    func sampler() -> InterfaceThroughputSampler {
        InterfaceThroughputSampler(readBuffer: { try self.routeBuffer() }, resolve: { self.resolve($0) },
                                   primaryInterface: { self.primary })
    }

    private func routeBuffer() throws -> [UInt8] {
        try state.withLock { state in
            if state.failsRouteRead { throw InterfaceThroughputSampler.ReadFailure(code: ENOMEM) }
            return state.buffer
        }
    }

    private func resolve(_ indices: [UInt16]) -> [UInt16: InterfaceThroughputSampler.Identity]? {
        state.withLock { state in
            state.resolutions.append(indices)
            if state.failsResolution { return nil }
            let number = state.resolutions.count
            return Dictionary(uniqueKeysWithValues: indices.map { index in
                (index, InterfaceThroughputSampler.Identity(name: "if\(index)", displayName: "Name \(number)",
                                                            addresses: ["10.0.0.\(index)"]))
            })
        }
    }
}
