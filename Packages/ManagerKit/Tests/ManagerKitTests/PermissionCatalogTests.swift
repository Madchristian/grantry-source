import Testing
import Foundation
@testable import ManagerKit

@Suite struct PermissionCatalogTests {
    @Test func knownServiceHasGermanNameAndDeeplink() {
        let camera = PermissionCatalog.service(for: "kTCCServiceCamera")
        #expect(camera.displayName == "Kamera")
        #expect(camera.systemImage == "camera")
        #expect(camera.settingsURL == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"))
        #expect(!camera.isSensitive)
    }

    @Test func automationServiceIDIsTheAppleEventsService() {
        #expect(PermissionCatalog.automationServiceID == "kTCCServiceAppleEvents")
        #expect(PermissionCatalog.service(for: PermissionCatalog.automationServiceID).displayName == "Automation")
    }

    @Test func sensitiveServicesAreFlagged() {
        for id in ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceAccessibility", "kTCCServiceScreenCapture", "kTCCServiceListenEvent"] {
            #expect(PermissionCatalog.service(for: id).isSensitive, "\(id)")
        }
    }

    @Test func unknownServiceFallsBackToRawID() {
        let unknown = PermissionCatalog.service(for: "kTCCServiceFutureThing")
        #expect(unknown.displayName == "kTCCServiceFutureThing")
        #expect(unknown.systemImage == "questionmark.square.dashed")
        #expect(unknown.settingsURL == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy"))
    }

    @Test func exactSetOfSensitiveServicesIsFlagged() {
        let sensitiveIDs = Set(PermissionCatalog.known.values.filter(\.isSensitive).map(\.id))
        #expect(sensitiveIDs == [
            "kTCCServiceScreenCapture",
            "kTCCServiceSystemPolicyAllFiles",
            "kTCCServiceAccessibility",
            "kTCCServicePostEvent",
            "kTCCServiceListenEvent",
            "kTCCServiceSystemPolicyAppBundles",
            "kTCCServiceAppleEvents",
            "kTCCServiceDeveloperTool",
            "kTCCServiceEndpointSecurityClient",
            "kTCCServiceRemoteDesktop",
            "kTCCServiceSystemPolicySysAdminFiles",
        ])
    }

    @Test func allKnownServiceIDsAreUnique() {
        #expect(PermissionCatalog.known.count == 25)
    }
}
