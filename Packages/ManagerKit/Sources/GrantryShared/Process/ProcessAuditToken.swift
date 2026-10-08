import Darwin
import Foundation

/// Audit-Token eines laufenden Prozesses – die **Prozessgeneration** (PID und `pidversion`), an die der Kernel ein Signal
/// bindet: `proc_signal_with_audittoken` trifft nur den Prozess, für den das Token gelesen wurde. Hat ein Nachfolger die
/// PID inzwischen bekommen, antwortet der Kernel `ESRCH` statt ihn zu treffen – anders als `kill(pid, …)`, das stets den
/// *jetzt* unter der PID laufenden Prozess trifft (#153, Befund 1).
///
/// Gelesen über `task_name_for_pid` und `task_info(TASK_AUDIT_TOKEN)`: für eigene Prozesse als Benutzer, als root
/// (Helper) für alle; für Zombies und fremde Prozesse ohne root nicht lesbar (`nil`).
public struct ProcessAuditToken: Hashable, Sendable {
    /// Die acht Werte von `audit_token_t` (Index 5: PID, Index 7: `pidversion`).
    private let values: [UInt32]

    private static let count = MemoryLayout<audit_token_t>.size / MemoryLayout<UInt32>.size

    /// Liest das Token des Prozesses `pid`; `nil`, wenn er nicht lesbar ist oder das Token nicht zu `pid` gehört.
    public init?(pid: pid_t) {
        guard pid > 0, let token = Self.read(pid) else { return nil }
        self.init(token)
        guard self.pid == pid else { return nil }
    }

    init(_ token: audit_token_t) {
        values = withUnsafeBytes(of: token.val) { Array($0.bindMemory(to: UInt32.self)) }
    }

    public var pid: pid_t { pid_t(bitPattern: values[5]) }

    /// Das Token für libproc.
    var raw: audit_token_t {
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token.val) { bytes in
            values.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        return token
    }

    private static func read(_ pid: pid_t) -> audit_token_t? {
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var size = mach_msg_type_number_t(count)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: count) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &size)
            }
        }
        guard result == KERN_SUCCESS, Int(size) == count else { return nil }
        return token
    }
}
