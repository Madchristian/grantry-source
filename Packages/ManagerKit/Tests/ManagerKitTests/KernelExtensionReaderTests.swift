import Foundation
import GrantryShared
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct KmutilShowloadedParserTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/Extensions")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Echte Ausgabe (macOS 27.2, nur Apple-Kexts): alle Zeilen lesbar, Kernbestandteile ohne Ladeadresse erkannt.
    @Test func realOutputWithAppleExtensionsOnly() throws {
        let loaded = try KmutilShowloadedParser.parse(fixture("kmutil-showloaded-apple-only"))
        #expect(loaded.unreadableLineCount == 0)
        #expect(loaded.records.count == 272)
        #expect(loaded.records.allSatisfy { AppleIdentifier.matches($0.bundleID) })
        let bsd = try #require(loaded.records.first { $0.bundleID == "com.apple.kpi.bsd" })
        #expect(bsd.isKernelResource)
        #expect(bsd.version == "27.2.0")
        #expect(bsd.path == nil)
        let smb = try #require(loaded.records.first { $0.bundleID == "com.apple.filesystems.smbfs" })
        #expect(!smb.isKernelResource)
        #expect(smb.version == "7.0")
    }

    @Test func thirdPartyLineAndBrokenLine() throws {
        let loaded = try KmutilShowloadedParser.parse(fixture("kmutil-showloaded-third-party"))
        #expect(loaded.unreadableLineCount == 1)
        let third = try #require(loaded.records.first { $0.bundleID == "com.example.thirdparty.driver" })
        #expect(third.version == "2.3.1")
        #expect(!third.isKernelResource)
    }

    @Test(arguments: ["", "No variant specified, falling back to release\n", "Error Domain=KMErrorDomain\n"])
    func missingHeaderThrows(_ output: String) {
        #expect(throws: KmutilShowloadedParser.FormatError.self) { try KmutilShowloadedParser.parse(output) }
    }
}

@Suite struct KextManagerRecordTests {
    /// Schlüssel wie von `KextManagerCopyLoadedKextInfo` (macOS 27.2): Kern ohne Pfad, Kernbestandteil, Apple-Kext,
    /// Drittanbieter; Einträge ohne Bundle-ID fallen weg.
    @Test func recordsFromLoadedKextInfo() {
        let info: [String: Any] = [
            "__kernel__": ["CFBundleIdentifier": "__kernel__", "CFBundleVersion": "27.2.0", "OSKernelResource": true],
            "com.apple.kpi.bsd": [
                "CFBundleIdentifier": "com.apple.kpi.bsd", "CFBundleVersion": "27.2.0", "OSKernelResource": true,
                "OSBundlePath": "/System/Library/Extensions/System.kext/PlugIns/BSDKernel.kext",
            ],
            "com.apple.filesystems.smbfs": [
                "CFBundleIdentifier": "com.apple.filesystems.smbfs", "CFBundleVersion": "7.0", "OSKernelResource": false,
                "OSBundlePath": "/System/Library/Extensions/smbfs.kext",
            ],
            "com.example.driver": [
                "CFBundleIdentifier": "com.example.driver\nFAKE", "CFBundleVersion": "1.2",
                "OSBundlePath": "/Library/Extensions/Example.kext",
            ],
            "broken": ["CFBundleVersion": "1.0"],
            "not a dictionary": "x",
        ]
        let records = KextManagerLoadedProvider.records(from: info).sorted { $0.bundleID < $1.bundleID }
        #expect(records.map(\.bundleID) == ["__kernel__", "com.apple.filesystems.smbfs", "com.apple.kpi.bsd", "com.example.driver FAKE"])
        #expect(records[0].isKernelResource && records[0].path == nil)
        #expect(!records[1].isKernelResource && records[1].path == "/System/Library/Extensions/smbfs.kext")
        #expect(records[3].version == "1.2")
    }
}

@Suite struct AppleKernelExtensionFilterTests {
    private let signing = FixedSigning(apple: ["/Library/Extensions/AppleSigned.kext"])

    @Test(arguments: [
        // Kernbestandteil und versiegeltes Systemvolume: Apple ohne Signaturprüfung.
        ("__kernel__", nil, true, true),
        ("com.apple.kpi.bsd", "/System/Library/Extensions/System.kext/PlugIns/BSDKernel.kext", true, true),
        ("com.apple.filesystems.smbfs", "/System/Library/Extensions/smbfs.kext", false, true),
        ("com.apple.driver.X", "/System/KernelKit/System/Library/Extensions/X.kext", false, true),
        // Außerhalb des versiegelten Volumes zählt die Signatur.
        ("com.apple.driver.Signed", "/Library/Extensions/AppleSigned.kext", false, true),
        ("com.apple.fake", "/Library/Extensions/Fake.kext", false, false),
        ("com.apple.fake", "/System/Library/Extensions/../../../Library/Extensions/Fake.kext", false, false),
        ("com.apple.fake", "/System/Library/Caches/Fake.kext", false, false),
        // Kein Apple-Präfix: nie ausgeblendet, auch nicht als Kernbestandteil oder mit Apple-Signatur.
        ("com.example.driver", "/System/Library/Extensions/Example.kext", false, false),
        ("com.example.driver", "/Library/Extensions/AppleSigned.kext", false, false),
        ("de.example.kpi", nil, true, false),
    ] as [(String, String?, Bool, Bool)])
    func appleOnlyWithPrefixAndProof(_ bundleID: String, _ path: String?, _ isKernelResource: Bool, _ expected: Bool) {
        let record = LoadedKernelExtensionRecord(bundleID: bundleID, version: nil, path: path, isKernelResource: isKernelResource)
        #expect(AppleKernelExtensionFilter(signing: signing).isApple(record) == expected)
    }

    /// Rückfall `kmutil` kennt keinen Pfad: `com.apple.*` gilt dort als Apple (dokumentierte Grenze).
    @Test func fallbackWithoutPathTrustsPrefix() {
        let record = LoadedKernelExtensionRecord(bundleID: "com.apple.driver.X", version: "1", path: nil, isKernelResource: false)
        #expect(AppleKernelExtensionFilter(signing: signing).isApple(record))
    }
}

@Suite struct InstalledKernelExtensionScannerTests {
    private func makeKext(_ name: String, in directory: URL, plist: [String: Any]?) throws {
        let contents = directory.appending(path: "\(name)/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        guard let plist else { return }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }

    @Test func missingDirectoryIsEmpty() {
        let scan = InstalledKernelExtensionScanner(directory: "/nonexistent-\(UUID().uuidString)").scan()
        #expect(scan.extensions.isEmpty)
        #expect(scan.unreadable.isEmpty)
    }

    @Test func readsBundlesSkipsOthersAndReportsUnreadable() throws {
        try ScratchDirectory.withCanonical(prefix: "kexts") { directory in
            try makeKext("Example.kext", in: directory, plist: [
                "CFBundleIdentifier": "com.example.driver", "CFBundleShortVersionString": "2.1",
                "CFBundleVersion": "210", "CFBundleName": "Example\u{202E} Treiber",
            ])
            try makeKext("BuildOnly.KEXT", in: directory, plist: ["CFBundleIdentifier": "com.example.build", "CFBundleVersion": "7"])
            try makeKext("NoPlist.kext", in: directory, plist: nil)
            try makeKext("NoID.kext", in: directory, plist: ["CFBundleVersion": "1"])
            try makeKext("Other.bundle", in: directory, plist: ["CFBundleIdentifier": "com.example.other"])
            try FileManager.default.createSymbolicLink(
                atPath: directory.appending(path: "Link.kext").path, withDestinationPath: directory.appending(path: "Example.kext").path
            )
            let linkedPlist = directory.appending(path: "LinkedPlist.kext/Contents")
            try FileManager.default.createDirectory(at: linkedPlist, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: linkedPlist.appending(path: "Info.plist").path,
                withDestinationPath: directory.appending(path: "Example.kext/Contents/Info.plist").path
            )

            let scan = InstalledKernelExtensionScanner(directory: directory.path).scan()

            #expect(scan.extensions == [
                KernelExtension(bundleID: "com.example.build", version: "7", name: nil, path: directory.appending(path: "BuildOnly.KEXT").path),
                KernelExtension(bundleID: "com.example.driver", version: "2.1", name: "Example Treiber", path: directory.appending(path: "Example.kext").path),
            ])
            #expect(scan.unreadable.map { URL(filePath: $0.path).lastPathComponent }.sorted()
                    == ["Link.kext", "LinkedPlist.kext", "NoID.kext", "NoPlist.kext"])
        }
    }

    @Test func entryLimitIsReported() throws {
        try ScratchDirectory.withCanonical(prefix: "kexts") { directory in
            for index in 0..<3 {
                try makeKext("K\(index).kext", in: directory, plist: ["CFBundleIdentifier": "com.example.k\(index)"])
            }
            let scan = InstalledKernelExtensionScanner(directory: directory.path, maximumEntries: 2).scan()
            #expect(scan.extensions.count == 2)
            #expect(scan.unreadable == [UnreadableExtension(path: directory.path, reason: ExtensionBundleScanner.entryLimitText(2))])
        }
    }
}

@Suite struct KernelExtensionReaderTests {
    private func reader(
        primary: any LoadedKernelExtensionProviding, fallback: any LoadedKernelExtensionProviding,
        directory: String = "/nonexistent-\(UUID().uuidString)", signing: any SigningInspecting = FixedSigning(apple: [])
    ) -> KernelExtensionReader {
        KernelExtensionReader(
            primary: primary, fallback: fallback, installed: InstalledKernelExtensionScanner(directory: directory), signing: signing
        )
    }

    private static let apple = LoadedKernelExtensionRecord(
        bundleID: "com.apple.kpi.bsd", version: "27.2.0", path: nil, isKernelResource: true
    )
    private static let thirdParty = LoadedKernelExtensionRecord(
        bundleID: "com.example.driver", version: "1.2", path: "/Library/Extensions/Example.kext", isKernelResource: false
    )

    @Test func hidesAppleAndKeepsThirdParty() async throws {
        let primary = FixedLoaded(.success(LoadedKernelExtensions(records: [Self.apple, Self.thirdParty], source: .kextManager)))
        let fallback = FixedLoaded(.failure(ExtensionReadError.unavailable("unbenutzt")))
        let list = try await reader(primary: primary, fallback: fallback).kernelExtensions()
        #expect(list.loaded == [KernelExtension(bundleID: "com.example.driver", version: "1.2", name: nil, path: "/Library/Extensions/Example.kext")])
        #expect(list.loadedSource == .kextManager)
        #expect(list.isComplete)
        #expect(fallback.callCount == 0)
    }

    @Test func fallsBackToKmutil() async throws {
        let primary = FixedLoaded(.failure(ExtensionReadError.unavailable("KextManager")))
        let fallback = FixedLoaded(.success(LoadedKernelExtensions(records: [Self.thirdParty], source: .kmutil, unreadableLineCount: 1)))
        let list = try await reader(primary: primary, fallback: fallback).kernelExtensions()
        #expect(list.loadedSource == .kmutil)
        #expect(list.loaded.map(\.bundleID) == ["com.example.driver"])
        #expect(!list.isComplete)
    }

    @Test func bothSourcesFailingThrowsFallbackError() async {
        let primary = FixedLoaded(.failure(ExtensionReadError.unavailable("KextManager")))
        let fallback = FixedLoaded(.failure(ExtensionReadError.unparseableOutput(command: "kmutil showloaded")))
        await #expect(throws: ExtensionReadError.unparseableOutput(command: "kmutil showloaded")) {
            try await reader(primary: primary, fallback: fallback).kernelExtensions()
        }
    }

    /// Installierte Apple-Kexts werden nur mit Apple-Signatur ausgeblendet.
    @Test func installedAppleNeedsSignature() async throws {
        try await ScratchDirectory.withCanonical(prefix: "kexts") { directory in
            for (name, id) in [("Signed.kext", "com.apple.signed"), ("Fake.kext", "com.apple.fake"), ("Vendor.kext", "com.example.vendor")] {
                let contents = directory.appending(path: "\(name)/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                try data.write(to: contents.appending(path: "Info.plist"))
            }
            let signing = FixedSigning(apple: [directory.appending(path: "Signed.kext").path])
            let primary = FixedLoaded(.success(LoadedKernelExtensions(records: [], source: .kextManager)))
            let list = try await reader(primary: primary, fallback: primary, directory: directory.path, signing: signing)
                .kernelExtensions()
            #expect(list.installed.map(\.bundleID) == ["com.apple.fake", "com.example.vendor"])
        }
    }
}

/// Apple-signiert genau für `apple`, sonst Developer ID.
private struct FixedSigning: SigningInspecting {
    let apple: Set<String>

    func inspect(path: String) -> SigningInfo {
        apple.contains(path) ? SigningInfo(kind: .apple) : SigningInfo(kind: .developerID, teamID: "TEAM")
    }
}

private final class FixedLoaded: LoadedKernelExtensionProviding {
    private let result: Result<LoadedKernelExtensions, ExtensionReadError>
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }

    init(_ result: Result<LoadedKernelExtensions, ExtensionReadError>) {
        self.result = result
    }

    func loadedExtensions() async throws -> LoadedKernelExtensions {
        calls.withLock { $0 += 1 }
        return try result.get()
    }
}
