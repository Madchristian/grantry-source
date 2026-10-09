import Darwin
import Foundation
import Synchronization

/// Ein vorwärtsbestätigter Reverse-DNS-Name für eine numerische Adresse; `nil` ohne bestätigten Namen.
public protocol ReverseDNSLookup: Sendable {
    func hostName(for address: String) async -> String?
}

/// PTR-Abfrage (`NI_NAMEREQD`) und Vorwärtsbestätigung (`getaddrinfo`) auf derselben eigenen Queue. Die
/// blockierenden Aufrufe belegen keinen Thread des kooperativen Pools. Nicht abbrechbar; das gemeinsame
/// Zeitlimit und die Belegung bis zum tatsächlichen Ende verwaltet `HostNameResolver`.
public struct SystemReverseDNSLookup: ReverseDNSLookup {
    private static let queue = DispatchQueue(label: "\(ManagerKit.logSubsystem).reverse-dns", qos: .utility,
                                             attributes: .concurrent)

    private let reverseLookup: @Sendable (String) -> String?
    private let forwardLookup: @Sendable (String) -> [String]

    public init() {
        self.init(reverseLookup: Self.lookUp, forwardLookup: Self.addresses)
    }

    init(reverseLookup: @escaping @Sendable (String) -> String?,
         forwardLookup: @escaping @Sendable (String) -> [String]) {
        self.reverseLookup = reverseLookup
        self.forwardLookup = forwardLookup
    }

    public func hostName(for address: String) async -> String? {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: confirmedName(for: address)) }
        }
    }

    private func confirmedName(for address: String) -> String? {
        guard let expected = Self.addressBytes(address),
              let name = reverseLookup(address), !name.isEmpty,
              forwardLookup(name).contains(where: { Self.addressBytes($0) == expected }) else { return nil }
        return name
    }

    /// Binär vergleichen: komprimierte IPv6-Adressen und andere Schreibweisen bezeichnen dieselbe Gegenstelle.
    private static func addressBytes(_ address: String) -> Data? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: v4) { Data($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: v6) { Data($0) } }
        return nil
    }

    private static func lookUp(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0,
                          NI_NAMEREQD) == 0 else { return nil }
        let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// Vorwärtsauflösung mit numerischer Ausgabe; `NI_NUMERICHOST` verhindert weitere PTR-Abfragen.
    private static func addresses(for hostName: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostName, nil, &hints, &info) == 0, let info else { return [] }
        defer { freeaddrinfo(info) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = info
        while let entry = current {
            defer { current = entry.pointee.ai_next }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            addresses.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return addresses
    }
}

/// Hostnamen zu Gegenstellen der Netzwerkaktivität (Spec §3): nur öffentliche Adressen (`IPAddressScope`), höchstens
/// `maximumConcurrentLookups` gleichzeitige Abfragen, Zeitlimit `timeout`, Cache (Name 10 min, kein Name 2 min).
///
/// Eine Abfrage über dem Zeitlimit liefert `nil` und gilt bis zum Ablauf des Negativ-Caches als „kein Name“; sie belegt
/// ihren Platz aber, bis der Systemaufruf tatsächlich endet, und trägt einen spät gefundenen Namen noch nach. Ist kein
/// Platz frei, wird nicht gewartet: `resolve` liefert sofort den Cache-Stand, der nächste Anlauf fragt erneut.
public final class HostNameResolver: Sendable {
    public static let defaultTimeout: Duration = .seconds(2)
    public static let defaultMaximumConcurrentLookups = 4
    public static let positiveLifetime: Duration = .seconds(10 * 60)
    public static let negativeLifetime: Duration = .seconds(2 * 60)
    /// Ab so vielen Cache-Einträgen räumt der Resolver beim nächsten Eintragen abgelaufene aus.
    public static let defaultCachePruneThreshold = 2048

    private struct Entry {
        let name: String?
        let expiresAt: ContinuousClock.Instant
    }

    private struct State {
        var cache: [String: Entry] = [:]
        var inFlight: Set<String> = []
    }

    private let lookup: any ReverseDNSLookup
    private let timeout: Duration
    private let maximumConcurrentLookups: Int
    private let cachePruneThreshold: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void
    private let state = Mutex(State())

    public init(
        lookup: any ReverseDNSLookup = SystemReverseDNSLookup(),
        timeout: Duration = defaultTimeout,
        maximumConcurrentLookups: Int = defaultMaximumConcurrentLookups,
        cachePruneThreshold: Int = defaultCachePruneThreshold,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.lookup = lookup
        self.timeout = timeout
        self.maximumConcurrentLookups = maximumConcurrentLookups
        self.cachePruneThreshold = cachePruneThreshold
        self.now = now
        self.sleep = sleep
    }

    /// Bekannter, nicht abgelaufener Name.
    public func cachedName(for address: String) -> String? {
        let instant = now()
        return state.withLock { state in
            state.cache[address].flatMap { $0.expiresAt > instant ? $0.name : nil }
        }
    }

    /// Anzahl der Cache-Einträge, auch abgelaufener (Tests).
    var cacheCount: Int { state.withLock { $0.cache.count } }

    /// Eine Abfrage wäre jetzt sinnvoll und möglich: öffentliche Adresse, kein gültiger Cache-Eintrag, keine laufende
    /// Abfrage, ein Platz frei.
    public func needsLookup(_ address: String) -> Bool {
        guard IPAddressScope.isPublic(address) else { return false }
        let instant = now()
        return state.withLock { canStart(address, in: $0, at: instant) }
    }

    /// Name zu `address`; fragt höchstens einmal gleichzeitig je Adresse und nur, wenn ein Platz frei ist – sonst sofort
    /// der Cache-Stand. Kehrt spätestens nach `timeout` zurück, bei Abbruch des Aufrufers sofort (`nil`); die Abfrage
    /// läuft dann weiter und trägt ihr Ergebnis noch in den Cache ein.
    public func resolve(_ address: String) async -> String? {
        guard IPAddressScope.isPublic(address) else { return nil }
        let instant = now()
        let started = state.withLock { state in
            guard canStart(address, in: state, at: instant) else { return false }
            state.inFlight.insert(address)
            return true
        }
        guard started else { return cachedName(for: address) }

        let outcome = OneShot<String?>()
        let timer = Task { [sleep, timeout] in
            try await sleep(timeout)
            outcome.resolve(nil)
        }
        Task { [lookup] in
            let name = await lookup.hostName(for: address)
            timer.cancel()
            self.finish(address, name: name)
            outcome.resolve(name)
        }
        let name = await withTaskCancellationHandler {
            await outcome.value
        } onCancel: {
            timer.cancel()
            outcome.resolve(nil)
        }
        if name == nil, !Task.isCancelled { recordTimeout(address) }
        return name
    }

    private func canStart(_ address: String, in state: State, at instant: ContinuousClock.Instant) -> Bool {
        !state.inFlight.contains(address) && state.inFlight.count < maximumConcurrentLookups
            && (state.cache[address].map { $0.expiresAt <= instant } ?? true)
    }

    private func finish(_ address: String, name: String?) {
        let instant = now()
        state.withLock { state in
            state.inFlight.remove(address)
            store(Entry(name: name, expiresAt: instant + (name == nil ? Self.negativeLifetime : Self.positiveLifetime)),
                  for: address, in: &state, at: instant)
        }
    }

    /// Zeitüberschreitung: „kein Name“ bis zum Ablauf des Negativ-Caches, außer die Abfrage hat inzwischen geantwortet.
    private func recordTimeout(_ address: String) {
        let instant = now()
        state.withLock { state in
            guard state.cache[address].map({ $0.expiresAt <= instant }) ?? true else { return }
            store(Entry(name: nil, expiresAt: instant + Self.negativeLifetime), for: address, in: &state, at: instant)
        }
    }

    /// Trägt `entry` ein; über `cachePruneThreshold` Einträgen fallen zuvor die abgelaufenen weg.
    private func store(_ entry: Entry, for address: String, in state: inout State, at instant: ContinuousClock.Instant) {
        state.cache[address] = entry
        if state.cache.count > cachePruneThreshold {
            state.cache = state.cache.filter { $0.value.expiresAt > instant }
        }
    }
}

/// Ein Wert, den der erste von mehreren Erzeugern setzt; Wartende werden suspendiert, nie blockiert.
final class OneShot<Value: Sendable>: Sendable {
    private enum State {
        case pending(waiters: [CheckedContinuation<Value, Never>])
        case resolved(Value)
    }

    private let state = Mutex(State.pending(waiters: []))

    /// Setzt den Wert, falls noch keiner gesetzt ist, und weckt alle Wartenden.
    func resolve(_ value: Value) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard case .pending(let waiters) = state else { return [] }
            state = .resolved(value)
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let resolved = state.withLock { state -> State? in
                    guard case .pending(var waiters) = state else { return state }
                    waiters.append(continuation)
                    state = .pending(waiters: waiters)
                    return nil
                }
                if case .resolved(let value) = resolved { continuation.resume(returning: value) }
            }
        }
    }
}
