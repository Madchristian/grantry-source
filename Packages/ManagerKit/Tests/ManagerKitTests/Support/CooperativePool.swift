import Foundation

/// Breite des kooperativen Pools im laufenden Testprozess.
enum CooperativePool {
    /// `true` mit `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (ein einziger Pool-Thread, Nachstellung weniger Kerne). Tests,
    /// die – wie in Produktion – eine synchrone Signaturprüfung auf einem Pool-Thread anhalten und zugleich auf eine
    /// Frist im Pool warten, brauchen einen zweiten Pool-Thread und laufen dann nicht.
    static var hasSingleThread: Bool {
        ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1"
    }
}
