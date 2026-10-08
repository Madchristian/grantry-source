import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct MachOHeaderTests {
    /// Erste Bytes echter Programme (`xxd`, 2026-10-03).
    static let keynoteUniversal: [UInt8] = [
        0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02,
        0x01, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x40, 0x00, 0x01, 0xE2, 0x17, 0xA0, 0x00, 0x00, 0x00, 0x0E,
        0x01, 0x00, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x01, 0xE2, 0x80, 0x00, 0x01, 0xB2, 0x7E, 0xB0, 0x00, 0x00, 0x00, 0x0E,
    ]
    static let xcodeARM64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]
    static let glkvmIntel: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01, 0x03, 0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0x00]

    private static func bigEndian(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

    /// FAT- (`entrySize` 20) bzw. FAT_64-Header (32) mit den CPU-Typen `cpus`; übrige Felder null.
    private static func fat(_ cpus: [UInt32], magic: UInt32 = 0xCAFE_BABE, entrySize: Int = 20) -> Data {
        var bytes = bigEndian(magic) + bigEndian(UInt32(cpus.count))
        for cpu in cpus { bytes += bigEndian(cpu) + [UInt8](repeating: 0, count: entrySize - 4) }
        return Data(bytes)
    }

    @Test func fatHeaderWithBothArchitecturesIsUniversal() {
        #expect(MachOHeader.architecture(of: Data(Self.keynoteUniversal)) == .universal)
    }

    @Test func thinARM64IsAppleSilicon() {
        #expect(MachOHeader.architecture(of: Data(Self.xcodeARM64)) == .appleSilicon)
    }

    @Test func thinX86_64IsIntel() {
        #expect(MachOHeader.architecture(of: Data(Self.glkvmIntel)) == .intel)
    }

    @Test func fat64HeaderIsRead() {
        #expect(MachOHeader.architecture(of: Self.fat([0x0100_0007, 0x0100_000C], magic: 0xCAFE_BABF, entrySize: 32)) == .universal)
    }

    @Test func fatWithOnlyOneFamily() {
        #expect(MachOHeader.architecture(of: Self.fat([0x0100_0007])) == .intel)
        #expect(MachOHeader.architecture(of: Self.fat([0x0100_000C])) == .appleSilicon)
    }

    /// Java-Klassendateien beginnen ebenfalls mit `CAFEBABE`, danach folgt die Version (≥ 45) statt der Anzahl.
    @Test func javaClassFileIsUnknown() {
        #expect(MachOHeader.architecture(of: Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34])) == .unknown)
    }

    @Test func truncatedFatHeaderIsUnknown() {
        #expect(MachOHeader.architecture(of: Data(Self.keynoteUniversal.prefix(30))) == .unknown)
    }

    @Test(arguments: [[0xFE, 0xED, 0xFA, 0xCE, 0x00, 0x00, 0x00, 0x12], [], [0x01, 0x02, 0x03]] as [[UInt8]])
    func powerPCAndGarbageAreUnknown(bytes: [UInt8]) {
        #expect(MachOHeader.architecture(of: Data(bytes)) == .unknown)
    }

    @Test func systemBinaryIsUniversal() {
        #expect(MachOHeader.architecture(ofExecutableAt: "/usr/bin/true") == .universal)
    }

    @Test func missingFileIsUnknown() {
        #expect(MachOHeader.architecture(ofExecutableAt: "/does/not/exist") == .unknown)
    }

    @Test func fifoIsUnknownWithoutBlocking() async throws {
        try await ScratchDirectory.with(prefix: "macho") { directory in
            let fifo = try FIFOFixture.make(in: directory)
            let result = await FIFOFixture.completes(unblocking: fifo) { MachOHeader.architecture(ofExecutableAt: fifo.path) }
            #expect(result == .unknown)
        }
    }

    /// Nur das Magic, kein CPU-Typ.
    @Test func thinHeaderWithFourBytesIsUnknown() {
        #expect(MachOHeader.architecture(of: Data(Self.xcodeARM64.prefix(4))) == .unknown)
    }

    /// 16 Einträge sind die Obergrenze; mehr gelten nicht als Programm.
    @Test func fatHeaderWithSeventeenEntriesIsUnknown() {
        let sixteen = [UInt32](repeating: 0x0100_000C, count: 15) + [0x0100_0007]
        #expect(MachOHeader.architecture(of: Self.fat(sixteen)) == .universal)
        #expect(MachOHeader.architecture(of: Self.fat(sixteen + [0x0100_000C])) == .unknown)
    }
}
