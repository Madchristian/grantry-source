import Foundation
import Testing
@testable import ManagerKit

@Suite struct DomainTests {
    @Test func authValueMapsTCCRawValues() {
        #expect(AuthValue(rawValue: 0) == .denied)
        #expect(AuthValue(rawValue: 2) == .allowed)
        #expect(AuthValue(rawValue: 3) == .limited)
        #expect(AuthValue(rawValue: 7) == .unknown(7))
    }

    @Test func authValueRawValueMatchesTCCEncoding() {
        #expect(AuthValue(rawValue: 2).rawValue == 2)
        #expect(AuthValue.unknown(7).rawValue == 7)
    }

    @Test func authValueJSONRoundTripsAsRawInt() throws {
        let values: [AuthValue] = [.allowed, .unknown(7)]
        let data = try JSONEncoder().encode(values)
        let ints = try JSONSerialization.jsonObject(with: data) as? [Int]
        #expect(ints == [2, 7])
        let decoded = try JSONDecoder().decode([AuthValue].self, from: data)
        #expect(decoded == values)
    }

    @Test func grantIDCombinesScopeServiceAndClient() {
        let grant = TestData.grant("kTCCServiceMicrophone", scope: .system)
        #expect(grant.id == "system|kTCCServiceMicrophone|us.zoom.xos")
        #expect(grant.source == .tccSystem)
        #expect(TestData.grant(scope: .user).source == .tccUser)
    }

    @Test func grantIDUsesStableClientIDOverAppIdentity() {
        let grant = PermissionGrant(
            service: "kTCCServiceCamera",
            client: TestData.app("x.y"),
            authValue: .allowed,
            scope: .user,
            lastModified: TestData.date,
            clientID: "/opt/tool"
        )
        #expect(grant.id == "user|kTCCServiceCamera|/opt/tool")
    }

    /// Automation hat pro Ziel-App eine eigene Zeile – das Ziel muss Teil der Identität sein.
    @Test func grantIDIncludesTargetOnlyWhenPresent() {
        func grant(target: String?) -> PermissionGrant {
            PermissionGrant(
                service: "kTCCServiceAppleEvents", client: TestData.app("us.zoom.xos"), authValue: .allowed,
                scope: .user, lastModified: TestData.date, clientID: "us.zoom.xos", target: target
            )
        }
        let finder = grant(target: "com.apple.finder")
        let systemEvents = grant(target: "com.apple.systemevents")

        #expect(finder.id == "user|kTCCServiceAppleEvents|us.zoom.xos|com.apple.finder")
        #expect(finder.id != systemEvents.id)
        #expect(grant(target: nil).id == "user|kTCCServiceAppleEvents|us.zoom.xos")
        #expect(TestData.grant("kTCCServiceCamera").id == "user|kTCCServiceCamera|us.zoom.xos")
    }

    @Test func appIdentifierPrefersBundleID() {
        let withBundle = AppIdentity(bundleID: "a.b", path: "/x", displayName: "X", signing: .unknown, presence: .present)
        let pathOnly = AppIdentity(bundleID: nil, path: "/usr/bin/ssh", displayName: "ssh", signing: .unknown, presence: .present)
        #expect(withBundle.identifier == "a.b")
        #expect(pathOnly.identifier == "/usr/bin/ssh")
    }

    @Test func appIdentifierFallsBackToDisplayName() {
        let noBundleNoPath = AppIdentity(bundleID: nil, path: nil, displayName: "Fallback", signing: .unknown, presence: .present)
        #expect(noBundleNoPath.identifier == "Fallback")
    }

    @Test func itemIDCombinesKindDomainAndLabel() {
        let item = TestData.item("com.docker.helper", kind: .launchDaemon, domain: .system)
        #expect(item.id == "launchDaemon|system|com.docker.helper")
    }

    @Test func grantSignificantChangeOnlyOnAuthValue() {
        let allowed = TestData.grant(authValue: .allowed)
        var touched = allowed
        touched.lastModified = allowed.lastModified.addingTimeInterval(60)
        #expect(!allowed.hasSignificantChanges(comparedTo: touched))
        #expect(allowed.hasSignificantChanges(comparedTo: TestData.grant(authValue: .denied)))
    }

    @Test func itemSignificantChangeOnEnabledLoadedOrProgram() {
        let base = TestData.item()
        var disabled = base
        disabled.isEnabled = false
        var unloaded = base
        unloaded.isLoaded = false
        var programChanged = base
        programChanged.program = "/usr/local/bin/other"
        var ownerChanged = base
        ownerChanged.owner = TestData.app()
        #expect(base.hasSignificantChanges(comparedTo: disabled))
        #expect(base.hasSignificantChanges(comparedTo: unloaded))
        #expect(base.hasSignificantChanges(comparedTo: programChanged))
        #expect(!base.hasSignificantChanges(comparedTo: ownerChanged))
    }

    @Test func itemLoadStateComparedOnlyWhenBothKnown() {
        let loaded = TestData.item()
        var unknown = loaded
        unknown.isLoaded = nil
        var unloaded = loaded
        unloaded.isLoaded = false
        #expect(!loaded.hasSignificantChanges(comparedTo: unknown))
        #expect(!unknown.hasSignificantChanges(comparedTo: loaded))
        #expect(loaded.hasSignificantChanges(comparedTo: unloaded))
    }

    @Test func itemProgramSigningIsNotASignificantChange() {
        let base = TestData.item()
        var signed = base
        signed.programSigning = SigningInfo(kind: .adHoc)
        var resigned = signed
        resigned.programSigning = SigningInfo(kind: .developerID, teamID: "T", isNotarized: true)
        #expect(!base.hasSignificantChanges(comparedTo: signed))
        #expect(!signed.hasSignificantChanges(comparedTo: resigned))
    }

    @Test func itemProgramSigningRoundTripsThroughJSON() throws {
        var item = TestData.item()
        item.programSigning = SigningInfo(kind: .unsigned)
        let decoded = try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
    }

    /// Snapshots von vor der Einführung von `programSigning` enthalten den Schlüssel nicht.
    @Test func itemWithoutProgramSigningKeyDecodesToNil() throws {
        let json = #"{"kind":"launchAgent","domain":"user","label":"x","program":"/bin/ls","programPresence":"present","isEnabled":true,"source":"launchd"}"#
        let item = try JSONDecoder().decode(AutostartItem.self, from: Data(json.utf8))
        #expect(item.programSigning == nil)
        #expect(item.program == "/bin/ls")
    }

    @Test func itemSessionTypesRoundTripAndAreNotASignificantChange() throws {
        var item = TestData.item()
        item.sessionTypes = ["Background"]
        let decoded = try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
        #expect(!item.hasSignificantChanges(comparedTo: TestData.item()))
    }

    @Test func itemWithoutSessionTypesKeyDecodesToNil() throws {
        let json = #"{"kind":"launchAgent","domain":"user","label":"x","programPresence":"present","isEnabled":true,"source":"launchd"}"#
        #expect(try JSONDecoder().decode(AutostartItem.self, from: Data(json.utf8)).sessionTypes == nil)
    }

    @Test func itemInterpreterLaunchRoundTripsAndDefaultsToFalse() throws {
        var item = TestData.item()
        #expect(!item.launchesInterpreter)
        item.launchesInterpreter = true
        #expect(try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item)) == item)
        let json = #"{"kind":"launchAgent","domain":"user","label":"x","programPresence":"present","isEnabled":true,"source":"launchd"}"#
        #expect(try JSONDecoder().decode(AutostartItem.self, from: Data(json.utf8)).launchesInterpreter == false)
    }

    /// Ältere Snapshots kennen nur `programIsScript` ohne Interpreter: Sie gelten bis zum nächsten Scan nicht als Skript.
    @Test func itemProgramScriptRoundTripsDefaultsToNilAndIsNotASignificantChange() throws {
        var item = TestData.item()
        #expect(item.programScript == nil)
        item.programScript = ProgramScript(interpreter: "/bin/sh", interpreterSigning: SigningInfo(kind: .apple))
        #expect(try JSONDecoder().decode(AutostartItem.self, from: JSONEncoder().encode(item)) == item)
        #expect(!item.hasSignificantChanges(comparedTo: TestData.item()))
        let json = #"{"kind":"launchAgent","domain":"user","label":"x","programPresence":"present","isEnabled":true,"source":"launchd","programIsScript":true}"#
        #expect(try JSONDecoder().decode(AutostartItem.self, from: Data(json.utf8)).programScript == nil)
    }

    /// Skript-Angaben aus Snapshots vor der `env`-Auflösung (`envProgram` als Name, ohne `arguments`) bleiben lesbar;
    /// `env` gilt dann bis zum nächsten Scan als nicht aufgelöst.
    @Test func programScriptDecodesTheOlderEnvFormat() throws {
        let json = #"{"interpreter":"/usr/bin/env","envProgram":"python3","interpreterSigning":{"kind":"apple","isNotarized":true}}"#
        let script = try JSONDecoder().decode(ProgramScript.self, from: Data(json.utf8))
        #expect(script.arguments == [])
        #expect(script.resolvedEnvProgram == nil)
        #expect(script.interpreterOrigin == .unknown)
        let current = ProgramScript(
            interpreter: "/usr/bin/env", arguments: ["python3"], interpreterSigning: SigningInfo(kind: .apple),
            resolvedEnvProgram: ProgramScript.ResolvedProgram(path: "/usr/bin/python3", signing: SigningInfo(kind: .apple))
        )
        #expect(try JSONDecoder().decode(ProgramScript.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func snapshotListsFailedSources() {
        let snapshot = TestData.snapshot(errors: [SourceError(source: .btm, message: "x")])
        #expect(snapshot.failedSources == [.btm])
    }

    @Test func signingInfoAppleFlag() {
        #expect(SigningInfo(kind: .apple).isAppleSigned)
        #expect(!SigningInfo(kind: .developerID).isAppleSigned)
    }

    @Test func changeEventDecodingRequiresBeforeOrAfter() {
        let json = Data(#"{"kind":"modified","detectedAt":0}"#.utf8)
        var thrown: Error?
        do {
            _ = try JSONDecoder().decode(ChangeEvent.self, from: json)
        } catch {
            thrown = error
        }
        #expect(thrown is DecodingError)
    }

    @Test func changeEventRoundTripsThroughJSON() throws {
        let event = ChangeEvent(
            kind: .modified,
            before: .grant(TestData.grant(authValue: .denied)),
            after: .grant(TestData.grant(authValue: .allowed)),
            detectedAt: TestData.date
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ChangeEvent.self, from: data)
        #expect(decoded == event)
    }
}
