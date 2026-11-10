import Foundation
import IOKit

/// Lesender Zugriff auf die IORegistry für die Messquellen des Task-Managers (Laufwerke, GPU, Chip). Objekte gelten nur
/// innerhalb der Closures und werden danach freigegeben.
enum IORegistryReader {
    struct LookupFailure: Error, Equatable {
        let className: String
        let code: kern_return_t
    }

    /// Ruft `body` für jeden Dienst der Klasse `className` auf.
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) throws {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator)
        guard result == KERN_SUCCESS else { throw LookupFailure(className: className, code: result) }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    /// Ergebnisse von `body` für die Kinder eines Gerätebaum-Knotens (`IODeviceTree:/cpus`), höchstens `limit`; leer,
    /// wenn es den Knoten nicht gibt.
    static func deviceTreeChildren<Result>(of path: String, limit: Int,
                                           _ body: (io_registry_entry_t) -> Result) -> [Result] {
        let parent = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard parent != 0 else { return [] }
        defer { IOObjectRelease(parent) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var results: [Result] = []
        var child = IOIteratorNext(iterator)
        while child != 0 {
            if results.count < limit { results.append(body(child)) }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return results
    }

    /// Name eines Eintrags ohne Einheitsadresse („ave0“).
    static func name(of entry: io_registry_entry_t) -> String? {
        var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return nil }
        let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Die genannten Eigenschaften eines Eintrags; fehlende entfallen.
    static func properties(_ keys: [String], of entry: io_registry_entry_t) -> [String: Any] {
        keys.reduce(into: [:]) { result, key in result[key] = property(key, of: entry) }
    }

    static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func dictionary(_ key: String, of entry: io_registry_entry_t) -> [String: Any]? {
        property(key, of: entry) as? [String: Any]
    }

    /// Elternobjekt in der Service-Ebene; `nil` ohne Eltern.
    static func withParent<Result>(of entry: io_registry_entry_t,
                                   _ body: (io_registry_entry_t) -> Result) -> Result? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return body(parent)
    }

    /// Erstes Kindobjekt in der Service-Ebene; `nil` ohne Kinder.
    static func withFirstChild<Result>(of entry: io_registry_entry_t,
                                       _ body: (io_registry_entry_t) -> Result) -> Result? {
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(entry, kIOServicePlane, &child) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(child) }
        return body(child)
    }

    /// Nicht negative Ganzzahl aus einem IORegistry-Wert (`NSNumber`).
    static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }

    /// Summe zweier Zähler; `nil`, wenn einer fehlt.
    static func sum(_ first: Any?, _ second: Any?) -> UInt64? {
        guard let first = uint64(first), let second = uint64(second) else { return nil }
        return first &+ second
    }
}
