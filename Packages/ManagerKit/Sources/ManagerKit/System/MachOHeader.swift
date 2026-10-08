import Foundation

/// Architektur eines Programms aus seinem Mach-O-Header – ohne `lipo` und ohne mehr als `readLength` Bytes zu lesen.
///
/// - Universal (`FAT_MAGIC` `CAFEBABE` bzw. `FAT_MAGIC_64` `CAFEBABF`, Big Endian): Anzahl, dann je Eintrag 20 bzw. 32
///   Byte, beginnend mit dem CPU-Typ. Mehr als `maximumFatArchitectures` Einträge sind kein Programm (Java-Klassendateien
///   tragen dort ihre Version ≥ 45).
/// - Einzeln (`MH_MAGIC_64` `FEEDFACF` bzw. `MH_MAGIC` `FEEDFACE`, Little Endian auf Intel und Apple Silicon): CPU-Typ
///   folgt dem Magic.
///
/// Gelesen wird nur eine reguläre Datei (`FileType.contentsOfRegularFile`, `O_NONBLOCK`) – eine FIFO blockiert nicht.
enum MachOHeader {
    static let readLength = 1024
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let magic64: UInt32 = 0xFEED_FACF
    private static let magic32: UInt32 = 0xFEED_FACE
    private static let fatEntrySize = 20
    private static let fat64EntrySize = 32
    private static let maximumFatArchitectures: UInt32 = 16
    private static let cpuTypeX86: UInt32 = 7
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    static func architecture(ofExecutableAt path: String) -> AppArchitecture {
        FileType.contentsOfRegularFile(atPath: path, maximumLength: readLength).map(architecture(of:)) ?? .unknown
    }

    static func architecture(of data: Data) -> AppArchitecture {
        let bytes = [UInt8](data.prefix(readLength))
        guard let magic = bytes.uint32(at: 0, bigEndian: true) else { return .unknown }
        if magic == fatMagic || magic == fatMagic64 {
            return fatArchitecture(bytes, entrySize: magic == fatMagic ? fatEntrySize : fat64EntrySize)
        }
        guard let littleEndianMagic = bytes.uint32(at: 0, bigEndian: false),
              littleEndianMagic == magic64 || littleEndianMagic == magic32,
              let cpu = bytes.uint32(at: 4, bigEndian: false) else { return .unknown }
        return classify([cpu])
    }

    private static func fatArchitecture(_ bytes: [UInt8], entrySize: Int) -> AppArchitecture {
        guard let count = bytes.uint32(at: 4, bigEndian: true), (1...maximumFatArchitectures).contains(count) else {
            return .unknown
        }
        let cpus = (0..<Int(count)).compactMap { bytes.uint32(at: 8 + $0 * entrySize, bigEndian: true) }
        return cpus.count == Int(count) ? classify(cpus) : .unknown
    }

    private static func classify(_ cpus: [UInt32]) -> AppArchitecture {
        let hasARM = cpus.contains(cpuTypeARM64)
        let hasIntel = cpus.contains(cpuTypeX86_64) || cpus.contains(cpuTypeX86)
        switch (hasARM, hasIntel) {
        case (true, true): return .universal
        case (true, false): return .appleSilicon
        case (false, true): return .intel
        case (false, false): return .unknown
        }
    }
}

private extension Array where Element == UInt8 {
    /// Vier Bytes ab `offset` als Zahl; `nil`, wenn sie nicht vollständig vorliegen.
    func uint32(at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let value = self[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return bigEndian ? value : value.byteSwapped
    }
}
