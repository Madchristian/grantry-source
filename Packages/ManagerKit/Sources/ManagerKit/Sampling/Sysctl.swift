import Darwin

/// Lesender Zugriff auf `sysctlbyname` für die Hardwarewerte des Task-Managers; fehlt ein Name, `nil`.
enum Sysctl {
    /// Längste gelesene Zeichenkette (Chipname); längere Werte gelten als unplausibel.
    static let maximumStringBytes = 256

    /// Ganzzahl mit 32 oder 64 Bit; negative Werte gelten als fehlend.
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        let number = size == MemoryLayout<Int32>.size ? Int64(Int32(truncatingIfNeeded: value)) : value
        return number >= 0 ? Int(number) : nil
    }

    static func uint64(_ name: String) -> UInt64? {
        int(name).map(UInt64.init)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size <= maximumStringBytes else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
