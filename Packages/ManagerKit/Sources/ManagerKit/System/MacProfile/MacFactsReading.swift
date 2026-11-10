import Foundation
import IOKit

/// Rohwerte des Steckbriefs, in Tests ersetzbar. Alle Abfragen sind synchron und kurz (sysctl, IORegistry, eine kleine
/// Datei); `MacProfileSource` ruft sie außerhalb des Main Actors auf. Fehlt ein Wert, `nil`.
protocol MacFactsReading: Sendable {
    /// `hw.model`.
    func modelIdentifier() -> String?
    /// Marketingname aus dem Gerätebaum (`IODeviceTree:/product`, `product-name`); fehlt auf Intel-Macs.
    func productName() -> String?
    /// `IODeviceTree:/chosen`, `system-firmware-version` („mBoot-20457.41.3“).
    func firmwareVersion() -> String?
    /// Inhalt von `SystemVersion.plist`.
    func systemVersionPlist() -> Data?
    func bootTime() -> Date?
    /// `kern.wakereason`.
    func wakeReason() -> String?
    /// `IOPlatformSerialNumber`; nur für `MacProfileSource.serialNumber()`.
    func serialNumber() -> String?
}

/// Liest die Werte dieses Macs ohne Root und ohne private API.
struct SystemMacFacts: MacFactsReading {
    static let systemVersionPath = "/System/Library/CoreServices/SystemVersion.plist"
    /// Größte gelesene `SystemVersion.plist`; echte sind unter 1 KB.
    static let maximumPlistBytes = 64 * 1024

    func modelIdentifier() -> String? { Sysctl.string("hw.model") }

    func productName() -> String? { Self.deviceTreeText("product-name", at: "IODeviceTree:/product") }

    func firmwareVersion() -> String? { Self.deviceTreeText("system-firmware-version", at: "IODeviceTree:/chosen") }

    func systemVersionPlist() -> Data? {
        guard let handle = FileHandle(forReadingAtPath: Self.systemVersionPath) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: Self.maximumPlistBytes)
    }

    func bootTime() -> Date? { SystemUptime.bootTime().map(SystemUptime.date) }

    func wakeReason() -> String? { Sysctl.string("kern.wakereason") }

    func serialNumber() -> String? {
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platform != 0 else { return nil }
        defer { IOObjectRelease(platform) }
        return IORegistryReader.property(kIOPlatformSerialNumberKey, of: platform) as? String
    }

    /// Text einer Gerätebaum-Eigenschaft (Daten bis zum ersten Nullbyte oder Zeichenkette); `nil` ohne Knoten.
    private static func deviceTreeText(_ key: String, at path: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        switch IORegistryReader.property(key, of: entry) {
        case let data as Data: return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        case let text as String: return text
        default: return nil
        }
    }
}
