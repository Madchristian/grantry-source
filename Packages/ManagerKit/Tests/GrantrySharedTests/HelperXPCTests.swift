import Testing
import Foundation
@testable import GrantryShared

@Suite struct HelperXPCTests {
    @Test func interfaceDescribesProtocol() {
        let interface = HelperXPC.makeInterface()
        #expect(interface.protocol === (GrantryHelperXPC.self as Protocol))
        #expect(HelperXPC.protocolVersion == 9)
        #expect(HelperXPC.terminateProcessMinimumVersion == 4)
        #expect(HelperXPC.taskManagerMinimumVersion == 9)
    }
}
