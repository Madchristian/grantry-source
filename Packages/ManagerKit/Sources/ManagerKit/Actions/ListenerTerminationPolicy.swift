import Foundation

/// Ob „Prozess beenden …“ für einen Lauscher angeboten wird (Spec §3). Beendbar sind alle Lauscher, die kein Dienst
/// von macOS sind (`isAppleService == false`) – auch Apple-signierte Interpreter des eigenen Benutzers.
public struct ListenerTerminationPolicy: Sendable {
    private let currentUID: UInt32
    private let ownBundlePath: String

    public init(currentUID: UInt32 = getuid(), ownBundlePath: String = Bundle.main.bundlePath) {
        self.currentUID = currentUID
        self.ownBundlePath = ownBundlePath
    }

    public func availability(for listener: NetworkListener, helperState: HelperState?) -> ActionAvailability {
        if listener.isAppleService { return .readOnly(.appleComponent) }
        if ProcessTerminationPolicy.isInBundle(listener.executablePath, bundlePath: ownBundlePath) { return .readOnly(.ownProcess) }
        guard listener.uid != currentUID else { return .available }
        guard helperState == .ready else { return .readOnly(.helperRequired) }
        // Der Helper lehnt Apple-Programme ab (`ProcessTerminationPolicy.helper()`); der Knopf scheiterte sonst immer.
        return listener.signing.isAppleSigned ? .readOnly(.foreignAppleProgram) : .available
    }
}
