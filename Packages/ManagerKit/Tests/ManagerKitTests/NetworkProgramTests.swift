import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkProgramTests {
    private let apple = SigningInfo(kind: .apple)
    private let developer = SigningInfo(kind: .developerID, teamID: "TEAMA12345", isNotarized: true)

    @Test func titleIsOutermostAppOrProcessName() {
        let helper = NetworkProgram(
            executablePath: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)",
            signing: developer
        )
        #expect(helper.bundlePath == "/Applications/Discord.app")
        #expect(helper.title == "Discord")
        #expect(helper.processName == "Discord Helper (Renderer)")

        let tool = NetworkProgram(executablePath: "/opt/homebrew/bin/node", signing: SigningInfo(kind: .adHoc))
        #expect(tool.bundlePath == nil)
        #expect(tool.title == "node")
    }

    @Test func appleServiceNeedsAppleSignatureOrSystemPathWhenUnknown() {
        #expect(NetworkProgram(executablePath: "/usr/libexec/rapportd", signing: apple).isAppleService)
        #expect(NetworkProgram(executablePath: "/usr/libexec/rapportd", signing: .unknown).isAppleService)
        #expect(!NetworkProgram(executablePath: "/usr/local/bin/redis-server", signing: .unknown).isAppleService)
        #expect(!NetworkProgram(executablePath: "/Applications/A.app/Contents/MacOS/A", signing: developer).isAppleService)
    }

    /// Interpreter und Netzwerkwerkzeuge sind nie Apple-Dienste, auch Apple-signiert im Systempfad.
    @Test func instructionDrivenProgramsAreNeverAppleServices() {
        let python = NetworkProgram(executablePath: "/usr/bin/python3", signing: apple)
        let netcat = NetworkProgram(executablePath: "/usr/bin/nc", signing: apple)
        #expect(python.isInterpreter && python.isInstructionDriven && !python.isAppleService)
        #expect(!netcat.isInterpreter && netcat.isInstructionDriven && !netcat.isAppleService)
    }

    @Test func listenerDelegatesToProgram() {
        let listener = TestData.listener("/usr/bin/python3", signing: apple)
        #expect(listener.program == NetworkProgram(executablePath: "/usr/bin/python3", signing: apple))
        #expect(listener.isAppleService == listener.program.isAppleService)
        #expect(listener.processName == "python3")
    }
}
