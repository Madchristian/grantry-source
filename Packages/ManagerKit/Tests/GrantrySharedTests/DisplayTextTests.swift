import Testing
@testable import GrantryShared

@Suite struct DisplayTextTests {
    /// Zeilenumbrüche, Steuer- und Formatzeichen (Bidi-Override) können keine Logzeile vortäuschen oder umdrehen.
    @Test(arguments: [
        ("listener", "listener"),
        ("evil\nFAKE: Signal gesendet", "evil FAKE: Signal gesendet"),
        ("  a\r\n\tb  ", "a b"),
        ("x\u{0007}y\u{202E}z\u{200B}", "xyz"),
    ])
    func singleLineRemovesControlCharacters(_ raw: String, _ expected: String) {
        #expect(DisplayText.singleLine(raw) == expected)
    }
}
