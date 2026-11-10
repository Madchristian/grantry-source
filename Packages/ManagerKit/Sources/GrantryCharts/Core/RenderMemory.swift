import Darwin

/// Speicher des eigenen Prozesses wie in der Abnahme (`phys_footprint`) und sein Grafik-Anteil, für Harness und
/// Render-Wächter (#521). Ein neu zeichnender `Canvas` lässt SwiftUI im Prozess per GPU rastern und legt dafür einen
/// Grafik-Pool von rund 257 MB an, unabhängig von Größe und Inhalt; Formen nicht. Der Pool zählt zum Footprint in der
/// Kategorie „graphics“ (`ledger_tag_graphics_footprint`).
public struct RenderMemory: Equatable, Sendable {
    /// Footprint jetzt, in Byte.
    public let footprint: UInt64
    /// Höchster Footprint seit dem Start des Prozesses, in Byte.
    public let peak: UInt64
    /// Grafik-Anteil des Footprints, in Byte.
    public let graphics: UInt64

    /// Stand des eigenen Prozesses; `nil`, wenn `task_info` ihn nicht liefert.
    public static func current() -> RenderMemory? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return RenderMemory(footprint: info.phys_footprint, peak: UInt64(info.ledger_phys_footprint_peak),
                            graphics: UInt64(info.ledger_tag_graphics_footprint))
    }
}
