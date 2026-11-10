#if DEBUG
import Foundation

/// Fester Stand des Tabs „Dienste“ für SwiftUI-Previews und Snapshots – ohne Systemzugriff: eigene Agenten (laufend,
/// beendet, mit Fehler), Apple-Dienste der Sitzung und System-Dienste mit einem verknüpften LaunchDaemon.
public enum ServiceListPreviewData {
    public static let uid: UInt32 = 501
    private static let home = "/Users/mara"

    public static var autostartItems: [AutostartItem] {
        [agent("com.mara.backup"), agent("homebrew.mxcl.postgresql@16"), agent("com.mara.sync"),
         AutostartItem(kind: .launchDaemon, domain: .system, label: "com.wazuh.agent",
                       program: "/Library/Ossec/bin/wazuh-control", programPresence: .present, isEnabled: true,
                       isLoaded: true, plistPath: "/Library/LaunchDaemons/com.wazuh.agent.plist", owner: nil,
                       source: .launchd)]
    }

    public static var listings: [LaunchdServiceDomain: [LaunchdServiceStatus]] {
        [
            .user(uid): [
                status("homebrew.mxcl.postgresql@16", pid: 8_123), status("com.mara.backup", exit: .exited(0)),
                status("com.mara.sync", exit: .exited(78)), status("com.apple.Finder", pid: 712),
                status("com.apple.cloudd", pid: 640), status("com.apple.syncdefaultsd", pid: 1_047),
                status("com.apple.findmy.findmylocateagent", pid: 55_271, exit: .other("(jt)")),
                status("com.apple.SafariHistoryServiceAgent"), status("com.apple.mediaanalysisd", exit: .signaled(9)),
                status("com.apple.Safari.SafeBrowsing.Service"),
            ],
            .system: [
                status("com.wazuh.agent", pid: 846), status("com.apple.mDNSResponder", pid: 312),
                status("com.apple.backupd", exit: .exited(0)), status("com.apple.coreservicesd", pid: 155),
            ],
        ]
    }

    public static var rows: [ServiceRow] {
        ServiceListPresenter.rows(listings, autostartItems: autostartItems)
    }

    public static func presentation(_ options: ServiceListOptions = ServiceListOptions()) -> ServiceListPresentation {
        ServiceListPresenter.present(rows, options: options)
    }

    private static func agent(_ label: String) -> AutostartItem {
        AutostartItem(kind: .launchAgent, domain: .user, label: label, program: "/opt/homebrew/bin/\(label)",
                      programPresence: .present, isEnabled: true, isLoaded: true,
                      plistPath: "\(home)/Library/LaunchAgents/\(label).plist", owner: nil, source: .launchd)
    }

    private static func status(_ label: String, pid: Int32? = nil,
                               exit: LaunchdExitStatus = .never) -> LaunchdServiceStatus {
        LaunchdServiceStatus(label: label, pid: pid, lastExit: exit)
    }
}
#endif
