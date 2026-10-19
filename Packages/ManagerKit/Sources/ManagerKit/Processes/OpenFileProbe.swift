import Darwin
import Foundation

/// Offene Datei oder Arbeitsordner eines laufenden Prozesses.
struct OpenPath: Hashable, Sendable {
    /// Name des gesuchten Prozesses, zu dessen Baum der Prozess gehört (etwa `xcodebuild` für einen Compiler darunter).
    let processName: String
    let path: String
}

/// Was die gesuchten Prozesse gerade benutzen (#226).
struct ProcessUsage: Hashable, Sendable {
    /// Gefundene Prozesse (gesuchte Namen), mit oder ohne offene Dateien.
    let running: Set<String>
    let openPaths: [OpenPath]

    /// Warum `path` gesperrt ist; `nil`, wenn nicht. Eine offene Datei darin (ohne Groß-/Kleinschreibung, APFS) sperrt
    /// immer, einen geteilten Eintrag (`ProcessLock.isShared`) schon ein laufender Prozess.
    func lockReason(for path: String, lock: ProcessLock) -> String? {
        let folder = path.lowercased()
        let user = openPaths.first { open in
            let candidate = open.path.lowercased()
            return candidate == folder || candidate.hasPrefix(folder + "/")
        }
        if let user { return "Wird gerade benutzt von \(user.processName)" }
        guard lock.isShared((path as NSString).lastPathComponent), let process = running.sorted().first else { return nil }
        return "Geteilter Cache, \(process) läuft"
    }
}

/// Offene Dateien und Arbeitsordner laufender Prozesse des eigenen Benutzers (#226): Einen Build-Ordner, den ein Build
/// gerade benutzt, löscht Grantry nicht.
protocol OpenFileProbing: Sendable {
    /// Laufende Prozesse mit einem Namen aus `names` (`p_comm`) samt Unterprozessen, ihre offenen Dateien und
    /// Arbeitsordner.
    func usage(ofProcessesNamed names: Set<String>) throws -> ProcessUsage
}

extension OpenFileProbing {
    /// Für Anzeige und Vorauswahl beim Scan; `nil` ohne Sperre oder wenn die Prozessliste nicht lesbar ist.
    func usage(for lock: ProcessLock?) -> ProcessUsage? {
        lock.flatMap { try? usage(ofProcessesNamed: $0.processes) }
    }

    /// Sperre unmittelbar vor dem Löschen: gesperrt → `.blocked`; nicht feststellbar → ebenfalls `.blocked` (fail-closed).
    func verdict(for path: String, lock: ProcessLock?) -> RemovalVerdict {
        guard let lock else { return .allowed }
        guard let usage = try? usage(ofProcessesNamed: lock.processes) else {
            return .blocked("Nicht prüfbar, ob ein Prozess den Ordner benutzt")
        }
        return usage.lockReason(for: path, lock: lock).map(RemovalVerdict.blocked) ?? .allowed
    }
}

/// `OpenFileProbing` über `sysctl(KERN_PROC_ALL)` (Namen und Eltern in einem Aufruf) und libproc (`PROC_PIDLISTFDS`,
/// `PROC_PIDFDVNODEPATHINFO`, Arbeitsordner). Liest nur eigene Prozesse; das erlaubt macOS ohne root.
struct LibprocOpenFileProbe: OpenFileProbing {
    private let currentUID: UInt32

    init(currentUID: UInt32 = getuid()) {
        self.currentUID = currentUID
    }

    func usage(ofProcessesNamed names: Set<String>) throws -> ProcessUsage {
        var own: [ProcessEntry] = []
        var processNames: [pid_t: String] = [:]
        for info in try LibprocProcessTable.kernelEntries() where info.kp_eproc.e_ucred.cr_uid == currentUID {
            let pid = info.kp_proc.p_pid
            guard pid > 0, Int32(info.kp_proc.p_stat) != SZOMB else { continue }
            own.append(ProcessEntry(pid: pid, parentPID: info.kp_eproc.e_ppid, uid: currentUID, startTime: 0))
            processNames[pid] = LibprocProcessTable.string(from: info.kp_proc.p_comm)
        }
        let children = Dictionary(grouping: own, by: \.parentPID)
        var visited = Set<pid_t>()
        var running = Set<String>()
        var openPaths: [OpenPath] = []
        for root in own {
            guard let name = processNames[root.pid], names.contains(name) else { continue }
            running.insert(name)
            for member in OrphanAgentTreeDetector.subtree(of: root, children: children) where visited.insert(member.pid).inserted {
                openPaths += Self.paths(of: member.pid).map { OpenPath(processName: name, path: $0) }
            }
        }
        return ProcessUsage(running: running, openPaths: openPaths)
    }

    /// Arbeitsordner und Pfade aller offenen Dateien (Vnodes) einer PID; leer, wenn sie nicht (mehr) lesbar ist.
    static func paths(of pid: pid_t) -> [String] {
        var paths = LibprocProcessTable.workingDirectory(of: pid).map { [$0] } ?? []
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return paths }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Reserve: zwischen den Aufrufen kann der Prozess weitere Dateien öffnen.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let filled = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return paths }
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size,
                  let path = LibprocProcessTable.string(from: vnode.pvip.vip_path) else { continue }
            paths.append(path)
        }
        return paths
    }
}
