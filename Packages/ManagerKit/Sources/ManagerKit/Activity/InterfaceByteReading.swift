import Foundation

/// Byte-Zähler aller Netzwerkschnittstellen zu einem Zeitpunkt – Grundlage des Plausibilitätsdeckels in
/// `TrafficTracker`. nettop zählt je Prozess die Nutzlast seiner Sockets; die Schnittstellen zählen dieselben Pakete
/// samt Kopfdaten, Loopback in beiden Richtungen. Mehr, als die Schnittstellen übertragen haben, können die Prozesse
/// zusammen nicht übertragen haben.
public struct InterfaceByteReading: Hashable, Sendable {
    /// Nach dem Lesen der Zähler.
    public let instant: ContinuousClock.Instant
    /// Empfangen + Senden je Schnittstellenindex.
    public let bytes: [UInt16: UInt64]

    public init(instant: ContinuousClock.Instant, bytes: [UInt16: UInt64]) {
        self.instant = instant
        self.bytes = bytes
    }

    /// Die Zähler aller Schnittstellen jetzt (`sysctl NET_RT_IFLIST2`, auch inaktive); `nil`, wenn nicht lesbar.
    public static func current() -> InterfaceByteReading? {
        guard let buffer = try? InterfaceThroughputSampler.routeBuffer() else { return nil }
        let interfaces = InterfaceThroughputSampler.parse(buffer)
        return InterfaceByteReading(
            instant: .now,
            bytes: Dictionary(interfaces.map { ($0.index, $0.bytesReceived &+ $0.bytesSent) }, uniquingKeysWith: max)
        )
    }

    /// Was alle Schnittstellen seit `earlier` übertragen haben. Eine neue oder zurückgesetzte Schnittstelle zählt mit
    /// ihrem ganzen Stand – lieber zu viel: Der Deckel darf echten Verkehr nicht kappen.
    func bytesTransferred(since earlier: InterfaceByteReading) -> UInt64 {
        bytes.reduce(0) { sum, interface in
            let before = earlier.bytes[interface.key].flatMap { $0 <= interface.value ? $0 : nil } ?? 0
            return sum &+ (interface.value - before)
        }
    }
}
