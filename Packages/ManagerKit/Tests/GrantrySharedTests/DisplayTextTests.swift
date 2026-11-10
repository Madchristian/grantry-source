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

    /// Überlange fremde Namen enden nach `maximumLength` Zeichen mit „…“; kürzere bleiben unverändert.
    @Test(arguments: [
        ("kurz", 10, "kurz"),
        ("genau zehn", 10, "genau zehn"),
        ("deutlich zu lang", 10, "deutlich …"),
        ("a\nb\u{202E}c", 3, "a …"),
        ("Grüße ☕︎ Tee", 8, "Grüße ☕︎…"),
    ])
    func singleLineLimitsLength(_ raw: String, _ maximumLength: Int, _ expected: String) {
        let text = DisplayText.singleLine(raw, maximumLength: maximumLength)
        #expect(text == expected)
        #expect(text.count <= maximumLength)
    }
}
