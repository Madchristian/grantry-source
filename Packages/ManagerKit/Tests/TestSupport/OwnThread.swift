import Foundation

/// Führt den blockierenden `body` auf einem eigenen Thread aus und wartet suspendierend auf sein Ergebnis.
///
/// Blockierendes Warten gehört nicht in den kooperativen Pool: Auf einem Runner mit drei Kernen hat er drei Threads, und
/// solange alle drei belegt sind – auch blockiert –, vergibt der Kernel keine weiteren Threads an die globalen
/// Dispatch-Queues. Wartet ein Pool-Thread auf Arbeit, die selbst eine solche Queue braucht (die Ressourcenprüfung in
/// `SecStaticCodeCheckValidity`, die Queue des `FileSizeCalculator`), hängt der ganze Testlauf, bis eine Frist greift.
public func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: body()) }
    }
}
