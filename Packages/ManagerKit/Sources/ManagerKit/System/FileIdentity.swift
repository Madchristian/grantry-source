import Darwin

/// Ein Dateisystemobjekt, festgemacht an Gerät (`st_dev`), Inode (`st_ino`) und Art – unabhängig von der Schreibweise
/// seines Pfads (APFS faltet Groß-/Kleinschreibung und Unicode weiter als `lowercased()`).
public struct FileIdentity: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case regularFile, directory, symbolicLink, other
    }

    public let device: Int32
    public let inode: UInt64
    public let type: Kind

    public init(device: Int32, inode: UInt64, type: Kind) {
        self.device = device
        self.inode = inode
        self.type = type
    }

    init(_ info: stat) {
        let type: Kind = switch info.st_mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
        self.init(device: info.st_dev, inode: info.st_ino, type: type)
    }

    /// Per `lstat` (folgt Symlinks nicht); `nil`, wenn der Pfad fehlt oder nicht erreichbar ist.
    public static func of(_ path: String) -> FileIdentity? {
        FileType.linkStatus(of: path).map(FileIdentity.init)
    }

    /// Dasselbe Objekt (Gerät und Inode), gleich unter welchem Pfad.
    func isSameObject(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }

    /// Gleiches Volume; ein Ordner auf einem anderen Volume als sein Elternordner ist ein Einhängepunkt.
    func isOnSameVolume(as other: FileIdentity) -> Bool {
        device == other.device
    }
}
