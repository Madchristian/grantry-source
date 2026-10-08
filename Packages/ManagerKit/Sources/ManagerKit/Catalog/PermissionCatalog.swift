import Foundation

/// Anzeige-Metadaten zu einem TCC-Service.
public struct PermissionService: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let systemImage: String
    public let settingsAnchor: String
    /// Berechtigungen mit weitreichendem Zugriff (für RiskRules).
    public let isSensitive: Bool

    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }
}

/// Bildet TCC-Service-IDs auf Anzeigenamen, SF-Symbole und Systemeinstellungs-Deeplinks ab.
public enum PermissionCatalog {
    /// TCC-Service der Automation-Berechtigung (Apple Events). `tccutil reset` setzt ihn für **alle** Ziel-Apps zurück.
    public static let automationServiceID = "kTCCServiceAppleEvents"

    public static func service(for id: String) -> PermissionService {
        known[id] ?? PermissionService(
            id: id, displayName: id, systemImage: "questionmark.square.dashed",
            settingsAnchor: "Privacy", isSensitive: false
        )
    }

    public static let known: [String: PermissionService] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0) }
    )

    private static let entries: [PermissionService] = [
        .init(id: "kTCCServiceCamera", displayName: "Kamera", systemImage: "camera", settingsAnchor: "Privacy_Camera", isSensitive: false),
        .init(id: "kTCCServiceMicrophone", displayName: "Mikrofon", systemImage: "mic", settingsAnchor: "Privacy_Microphone", isSensitive: false),
        .init(id: "kTCCServiceScreenCapture", displayName: "Bildschirmaufnahme", systemImage: "rectangle.dashed.badge.record", settingsAnchor: "Privacy_ScreenCapture", isSensitive: true),
        .init(id: "kTCCServiceSystemPolicyAllFiles", displayName: "Festplattenvollzugriff", systemImage: "internaldrive", settingsAnchor: "Privacy_AllFiles", isSensitive: true),
        .init(id: "kTCCServiceAccessibility", displayName: "Bedienungshilfen", systemImage: "accessibility", settingsAnchor: "Privacy_Accessibility", isSensitive: true),
        .init(id: "kTCCServicePostEvent", displayName: "Eingaben simulieren", systemImage: "keyboard.badge.ellipsis", settingsAnchor: "Privacy_Accessibility", isSensitive: true),
        .init(id: "kTCCServiceListenEvent", displayName: "Eingabeüberwachung", systemImage: "keyboard", settingsAnchor: "Privacy_ListenEvent", isSensitive: true),
        .init(id: "kTCCServiceAddressBook", displayName: "Kontakte", systemImage: "person.crop.circle", settingsAnchor: "Privacy_Contacts", isSensitive: false),
        .init(id: "kTCCServiceCalendar", displayName: "Kalender", systemImage: "calendar", settingsAnchor: "Privacy_Calendars", isSensitive: false),
        .init(id: "kTCCServiceReminders", displayName: "Erinnerungen", systemImage: "checklist", settingsAnchor: "Privacy_Reminders", isSensitive: false),
        .init(id: "kTCCServicePhotos", displayName: "Fotos", systemImage: "photo.on.rectangle", settingsAnchor: "Privacy_Photos", isSensitive: false),
        .init(id: automationServiceID, displayName: "Automation", systemImage: "gearshape.2", settingsAnchor: "Privacy_Automation", isSensitive: true),
        .init(id: "kTCCServiceSystemPolicyDesktopFolder", displayName: "Schreibtisch-Ordner", systemImage: "menubar.dock.rectangle", settingsAnchor: "Privacy_FilesAndFolders", isSensitive: false),
        .init(id: "kTCCServiceSystemPolicyDocumentsFolder", displayName: "Dokumente-Ordner", systemImage: "doc", settingsAnchor: "Privacy_FilesAndFolders", isSensitive: false),
        .init(id: "kTCCServiceSystemPolicyDownloadsFolder", displayName: "Downloads-Ordner", systemImage: "arrow.down.circle", settingsAnchor: "Privacy_FilesAndFolders", isSensitive: false),
        .init(id: "kTCCServiceSystemPolicyNetworkVolumes", displayName: "Netzwerkvolumes", systemImage: "network", settingsAnchor: "Privacy_FilesAndFolders", isSensitive: false),
        .init(id: "kTCCServiceSystemPolicyRemovableVolumes", displayName: "Wechselmedien", systemImage: "externaldrive", settingsAnchor: "Privacy_FilesAndFolders", isSensitive: false),
        .init(id: "kTCCServiceSystemPolicyAppBundles", displayName: "App-Verwaltung", systemImage: "app.badge", settingsAnchor: "Privacy_AppBundles", isSensitive: true),
        .init(id: "kTCCServiceDeveloperTool", displayName: "Entwickler-Tools", systemImage: "hammer", settingsAnchor: "Privacy_DevTools", isSensitive: true),
        .init(id: "kTCCServiceBluetoothAlways", displayName: "Bluetooth", systemImage: "wave.3.right", settingsAnchor: "Privacy_Bluetooth", isSensitive: false),
        .init(id: "kTCCServiceMediaLibrary", displayName: "Medien & Apple Music", systemImage: "music.note", settingsAnchor: "Privacy_Media", isSensitive: false),
        .init(id: "kTCCServiceSpeechRecognition", displayName: "Spracherkennung", systemImage: "waveform", settingsAnchor: "Privacy_SpeechRecognition", isSensitive: false),
        .init(id: "kTCCServiceEndpointSecurityClient", displayName: "Endpoint Security", systemImage: "shield.lefthalf.filled", settingsAnchor: "Privacy_AllFiles", isSensitive: true),
        .init(id: "kTCCServiceRemoteDesktop", displayName: "Bildschirmfernsteuerung", systemImage: "display.2", settingsAnchor: "Privacy", isSensitive: true),
        .init(id: "kTCCServiceSystemPolicySysAdminFiles", displayName: "Administrator-Dateien", systemImage: "lock.doc", settingsAnchor: "Privacy", isSensitive: true),
    ]
}
