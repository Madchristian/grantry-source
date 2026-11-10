import Testing
@testable import ManagerKit

/// Je Art ein eigener Erklärsatz, was sie darf (#390).
struct ExtensionTextsTests {
    static let kinds: [ExtensionKind] = [
        .kernelExtension, .driver, .network, .endpointSecurity, .camera,
        .otherSystemExtension("com.apple.system_extension.new"), .audioPlugin, .videoPlugin,
    ]

    @Test(arguments: kinds) func everyKindHasOneSentence(_ kind: ExtensionKind) {
        let text = kind.permissionText
        #expect(text.hasSuffix("."))
        #expect(!text.contains("\n"))
        #expect(text.count > 20)
    }

    @Test func sentencesAreDistinct() {
        #expect(Set(Self.kinds.map(\.permissionText)).count == Self.kinds.count)
    }

    /// Unbekannte Arten nennen ihre Kennung nicht im Erklärsatz – sie stammt aus fremder Ausgabe.
    @Test func unknownKindsShareOneSentence() {
        #expect(ExtensionKind.otherSystemExtension("a").permissionText == ExtensionKind.otherSystemExtension("b").permissionText)
    }
}
