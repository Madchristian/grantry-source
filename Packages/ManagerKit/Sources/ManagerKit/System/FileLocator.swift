import Darwin

/// Wo ein Dateisystemobjekt (`FileIdentity`) jetzt liegt – unabhängig vom Pfad, unter dem es zuletzt gesehen wurde.
enum FileLocation: Equatable, Sendable {
    /// Ein aktueller Pfad des Objekts. `hasOtherNames`: reguläre Datei mit `st_nlink > 1` – sie hat weitere harte
    /// Verknüpfungen, von denen `path` nur eine ist (Ordner haben keine).
    case found(path: String, hasOtherNames: Bool)
    /// Kein Objekt mit dieser Identität mehr auf dem Volume (gelöscht). APFS vergibt Inodes nicht erneut; auf HFS+
    /// könnte eine wiederverwendete CNID ein fremdes neues Objekt zeigen – `lstat` erkennt das nicht.
    case gone
    /// Nicht ermittelbar: Pfad nicht aufbaubar (kein Suchrecht auf einem Ordner, Volume ohne Unterstützung,
    /// `ENOTSUP`) oder Objekt zwischen `fsgetpath` und `lstat` wieder verändert.
    case unknown
}

/// Findet ein Objekt über Gerät und Inode wieder; in Tests eine Attrappe.
protocol FileLocating: Sendable {
    func locate(_ identity: FileIdentity) -> FileLocation
}

/// `fsgetpath(2)`: Der Kernel baut den Pfad zu Volume (`st_dev` als `fsid`) und Inode auf – ohne Root nur, wenn der
/// Aufrufer jeden Ordner darin durchsuchen darf (`BUILDPATH_CHECKACCESS`); Firmlinks kommen übersetzt zurück
/// (`/Library`, nicht `/System/Volumes/Data/Library`). `ENOENT` heißt: kein solches Objekt mehr. Der gefundene Pfad
/// muss per `lstat` noch dasselbe Objekt zeigen.
struct FSGetPathLocator: FileLocating {
    func locate(_ identity: FileIdentity) -> FileLocation {
        var fsid = fsid_t(val: (identity.device, 0))
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = fsgetpath(&buffer, buffer.count, &fsid, identity.inode)
        guard length >= 0 else { return errno == ENOENT ? .gone : .unknown }
        let path = String(cString: buffer)
        guard let status = FileType.linkStatus(of: path), FileIdentity(status).isSameObject(as: identity) else { return .unknown }
        return .found(path: path, hasOtherNames: status.st_mode & S_IFMT == S_IFREG && status.st_nlink > 1)
    }
}
