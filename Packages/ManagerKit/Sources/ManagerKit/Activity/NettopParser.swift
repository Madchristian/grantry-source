import Darwin
import Foundation

/// Liest einen Block von `nettop -n -x -J state,bytes_in,bytes_out` (CSV):
///
/// ```
/// ,state,bytes_in,bytes_out,
/// apsd.577,,4727302,10165988,
/// tcp4 192.0.2.235:63199<->192.0.2.25:5223,Established,4727302,10165988,
/// ```
///
/// - Kopfzeile genau `,state,bytes_in,bytes_out,`, sonst `Error.unrecognizedFormat`.
/// - Prozesszeile `<name>.<pid>,,<in>,<out>,`: Der Name ist gekürzt und kann Punkte und Kommas enthalten, die PID ist
///   das letzte durch `.` getrennte Feld. Unlesbare Prozesszeilen und ihre folgenden Verbindungen werden gezählt
///   und übersprungen, bis wieder eine lesbare Prozesszeile die Zuordnung erlaubt.
/// - Verbindungszeile `<proto> <lokal><-><entfernt>,<state>,<in>,<out>,` mit `proto` = `tcp|udp|quic` + `4|6`. Eine
///   unlesbare Verbindungszeile wird übersprungen und gezählt (`NettopSample.skippedLineCount`).
public enum NettopParser {
    /// Erwartete Kopfzeile jedes Blocks.
    public static let header = ",state,bytes_in,bytes_out,"

    public enum Error: Swift.Error, Equatable {
        case unrecognizedFormat
    }

    public static func parse(block: String) throws -> NettopSample {
        // `isNewline` trifft auch `\r\n` – in Swift ein einziges Zeichen.
        let lines = block.split(whereSeparator: \.isNewline)
        guard lines.first == Substring(header) else { throw Error.unrecognizedFormat }
        var processes: [ProcessTraffic] = []
        var skipped = 0
        var currentProcessIndex: Int?
        for line in lines.dropFirst() {
            // Der frei wählbare Name darf wie eine Kopf- oder Verbindungszeile aussehen.
            if let process = process(from: line) {
                processes.append(process)
                currentProcessIndex = processes.count - 1
            } else if isConnectionLine(line) {
                if let index = currentProcessIndex, let connection = connection(from: line) {
                    processes[index].connections.append(connection)
                } else {
                    skipped += 1
                }
            } else {
                // Ohne lesbaren Prozess dürfen seine Verbindungen nicht beim Vorgänger landen.
                currentProcessIndex = nil
                skipped += 1
            }
        }
        return NettopSample(processes: processes, skippedLineCount: skipped)
    }

    /// PID einer Prozesszeile; `nil` für Kopf-, Verbindungs- und unlesbare Zeilen.
    static func processID(ofLine line: Substring) -> Int32? {
        process(from: line)?.pid
    }

    /// `tcp4 …<->…` – Kleinbuchstaben mit Versionsziffer, dann Leerzeichen, dazu der Pfeil.
    private static func isConnectionLine(_ line: Substring) -> Bool {
        // Auch mit unlesbaren Byte-Feldern bleibt eine erkennbare Prozesszeile eine Zuordnungsgrenze.
        guard processFields(from: line) == nil,
              let space = line.firstIndex(of: " "), line.contains("<->") else { return false }
        return line[..<space].wholeMatch(of: /[a-z]+[0-9]/) != nil
    }

    private static func process(from line: Substring) -> ProcessTraffic? {
        guard let fields = processFields(from: line),
              let bytesIn = ByteField(fields.received), let bytesOut = ByteField(fields.sent) else { return nil }
        return ProcessTraffic(pid: fields.pid, shortName: fields.name, bytesIn: bytesIn.value, bytesOut: bytesOut.value)
    }

    /// Prozessstruktur unabhängig von den Byte-Werten; Kommas im Namen gehören zum Label.
    private static func processFields(from line: Substring)
        -> (name: String, pid: Int32, received: Substring, sent: Substring)? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 5, fields.removeLast().isEmpty else { return nil }
        let sent = fields.removeLast()
        let received = fields.removeLast()
        guard fields.removeLast().isEmpty else { return nil }
        let label = fields.joined(separator: ",")
        guard !isIPv6ConnectionLabel(label) else { return nil }
        guard let dot = label.lastIndex(of: "."), let pid = Int32(label[label.index(after: dot)...]), pid >= 0 else { return nil }
        let name = label[..<dot].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (name: name, pid: pid, received: received, sent: sent)
    }

    /// IPv6 trennt den Port ebenfalls mit einem Punkt. Vollständige Endpunktpaare bleiben deshalb Verbindungen,
    /// auch bei leerem UDP-/QUIC-Status; ein bloßes Protokollpräfix im Prozessnamen reicht dafür nicht.
    private static func isIPv6ConnectionLabel(_ label: String) -> Bool {
        guard let space = label.firstIndex(of: " "),
              label[..<space].wholeMatch(of: /[a-z]+6/) != nil,
              let arrow = label.range(of: "<->"),
              let local = ConnectionEndpoint(nettop: label[label.index(after: space)..<arrow.lowerBound], version: .v6),
              let remote = ConnectionEndpoint(nettop: label[arrow.upperBound...], version: .v6) else { return false }
        return [local, remote].allSatisfy { endpoint in
            guard let address = endpoint.address else { return true }
            let plain = String(address.prefix { $0 != "%" })
            var bytes = in6_addr()
            return inet_pton(AF_INET6, plain, &bytes) == 1
        }
    }

    private static func connection(from line: Substring) -> ConnectionTraffic? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 5, fields[4].isEmpty, let space = fields[0].firstIndex(of: " ") else { return nil }
        let proto = fields[0][..<space]
        let pair = fields[0][fields[0].index(after: space)...]
        guard let transport = ConnectionTransport(rawValue: String(proto.dropLast())),
              let version = IPVersion(digit: proto.last),
              let arrow = pair.firstRange(of: "<->"),
              let local = ConnectionEndpoint(nettop: pair[..<arrow.lowerBound], version: version),
              let remote = ConnectionEndpoint(nettop: pair[arrow.upperBound...], version: version),
              let bytesIn = ByteField(fields[2]), let bytesOut = ByteField(fields[3]) else { return nil }
        return ConnectionTraffic(transport: transport, ipVersion: version, local: local, remote: remote,
                                 state: String(fields[1]), bytesIn: bytesIn.value, bytesOut: bytesOut.value)
    }

    /// Byte-Feld: leer oder eine Zahl; alles andere ist unlesbar (`nil` beim Erzeugen).
    private struct ByteField {
        let value: UInt64?

        init?(_ field: Substring) {
            if field.isEmpty {
                value = nil
            } else if let number = UInt64(field) {
                value = number
            } else {
                return nil
            }
        }
    }
}
