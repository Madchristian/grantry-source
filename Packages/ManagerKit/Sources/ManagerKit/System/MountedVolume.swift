import Darwin

/// Eingehängtes Dateisystem: Einhängepunkt, ob es lokal ist (`MNT_LOCAL`), und das Gerät dahinter.
struct MountedVolume: Equatable, Sendable {
    let path: String
    let isLocal: Bool
    /// Gerätekennung („disk3s5“) bei Geräten unter `/dev`; `nil` für Netz- und Pseudo-Dateisysteme.
    let device: String?

    /// Firmlink-Ziel des Datenvolumes: Einhängepunkte darunter (autofs-Maps `/home`, `/Network/Servers`) erscheinen in
    /// Pfaden ohne dieses Präfix.
    static let dataVolumePrefix = "/System/Volumes/Data"

    init(path: String, isLocal: Bool, device: String? = nil) {
        self.path = path
        self.isLocal = isLocal
        self.device = device
    }

    /// Einhängepunkt laut Kernel; `/System/Volumes/Data/<x>` wird zu `/<x>` (das Datenvolume selbst bleibt).
    /// `deviceNode` ist die Quelle laut Kernel („/dev/disk3s5“, „//server/freigabe“).
    init(mountPoint: String, isLocal: Bool, deviceNode: String = "") {
        let devicePrefix = "/dev/"
        self.init(path: Self.firmlinkedPath(mountPoint), isLocal: isLocal,
                  device: deviceNode.hasPrefix(devicePrefix) ? String(deviceNode.dropFirst(devicePrefix.count)) : nil)
    }

    /// `/System/Volumes/Data/<x>` als `/<x>`, wie Pfade außerhalb des Datenvolumes es schreiben; das Datenvolume selbst
    /// und alle übrigen Pfade bleiben.
    static func firmlinkedPath(_ path: String) -> String {
        let prefix = dataVolumePrefix + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count - 1)) : path
    }

    /// Einhängepunkte laut Kernel (`getfsstat` mit `MNT_NOWAIT`: zwischengespeicherte Angaben, blockiert nicht an einem
    /// hängenden Netzlaufwerk). Leer, wenn die Abfrage scheitert.
    @Sendable static func current() -> [MountedVolume] {
        let expected = getfsstat(nil, 0, MNT_NOWAIT)
        guard expected > 0 else { return [] }
        // Etwas Reserve, falls zwischen beiden Aufrufen ein Volume hinzukommt.
        var buffer: [statfs] = Array(repeating: statfs(), count: Int(expected) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer in
            getfsstat(pointer.baseAddress, Int32(pointer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map { system in
            var name = system.f_mntonname
            var source = system.f_mntfromname
            let path = withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let node = withUnsafeBytes(of: &source) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return MountedVolume(mountPoint: path, isLocal: system.f_flags & UInt32(MNT_LOCAL) != 0, deviceNode: node)
        }
    }

    /// Das innerste Volume, das `path` enthält (längster passender Einhängepunkt); `nil`, wenn keines passt.
    static func containing(_ path: String, in volumes: [MountedVolume]) -> MountedVolume? {
        volumes
            .filter { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Einhängepunkt `/Volumes/<name>`, unter dem `path` liegt; `nil` außerhalb von `/Volumes`.
    static func volumesMountPoint(of path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return prefix + name
    }
}
