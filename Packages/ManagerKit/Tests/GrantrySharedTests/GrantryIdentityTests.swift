import Testing
import Foundation
import Security
@testable import GrantryShared

@Suite struct GrantryIdentityTests {
    @Test(arguments: [
        GrantryIdentity.appRequirement,
        GrantryIdentity.releaseAppRequirement,
        GrantryIdentity.helperRequirement,
    ])
    func requirementCompiles(_ text: String) {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func releaseRequirementExcludesGetTaskAllow() {
        #expect(GrantryIdentity.releaseAppRequirement.hasPrefix(GrantryIdentity.appRequirement))
        #expect(GrantryIdentity.releaseAppRequirement.hasSuffix(
            #" and !(entitlement["com.apple.security.get-task-allow"] exists)"#
        ))
    }

    @Test func releaseRequirementDemandsDeveloperIDCertificate() {
        #expect(GrantryIdentity.releaseAppRequirement.contains(
            " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        ))
        #expect(!GrantryIdentity.appRequirement.contains("1.2.840.113635.100.6.1.13"))
    }
}
