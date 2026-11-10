/// Orte im Benutzerordner, deren Lesen ohne Festplattenvollzugriff eine Rückfrage von macOS auf den Bildschirm bringt
/// (Schreibtisch, Dokumente, Downloads, iCloud Drive, App-Container, Cloud-Speicher, Kontakte, Kalender, Erinnerungen,
/// Fotomediathek). Die Belegung lässt sie dann aus (`OccupancyScanner(excluding:)`); sie zählen als nicht erfasst.
public enum OccupancyProtectedPlaces {
    static let relativePaths = [
        "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/Containers", "Library/Group Containers",
        "Library/CloudStorage", "Library/Application Support/AddressBook", "Library/Calendars", "Library/Reminders",
        "Pictures/Photos Library.photoslibrary",
    ]

    /// Die Orte unter `home`, so geschrieben, wie der Scan ab `scanRoot` sie sieht: ab dem Datenvolume
    /// (`/System/Volumes/Data`) mit dessen Präfix, sonst wie `home`.
    public static func folders(inHome home: String, scanRoot: String? = nil) -> Set<String> {
        let prefix = scanRoot.map { RawPath.isPath($0, atOrBelow: MountedVolume.dataVolumePrefix) } == true
            && !RawPath.isPath(home, atOrBelow: MountedVolume.dataVolumePrefix) ? MountedVolume.dataVolumePrefix : ""
        return Set(relativePaths.map { prefix + home + "/" + $0 })
    }
}
