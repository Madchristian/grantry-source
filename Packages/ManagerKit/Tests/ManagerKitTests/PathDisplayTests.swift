import Testing
@testable import ManagerKit

@Suite struct PathDisplayTests {
    @Test(arguments: [
        ("/Users/test/Library/Caches/x", "~/Library/Caches/x"), ("/Users/test", "~"),
        ("/Users/tester/x", "/Users/tester/x"), ("/Applications/X.app", "/Applications/X.app"),
    ])
    func abbreviatesOnlyWholeComponents(path: String, expected: String) {
        #expect(PathDisplay.abbreviatingHome(path, home: "/Users/test/") == expected)
    }

    @Test(arguments: [
        ("nicht lesbar (/Users/test/.claude.json): verweigert", "nicht lesbar (~/.claude.json): verweigert"),
        ("/Users/test/a und /Users/test/b", "~/a und ~/b"),
        ("Datei „/Users/test/x.toml“ fehlt", "Datei „~/x.toml“ fehlt"),
        ("Pfad \"/Users/test/x\"", "Pfad \"~/x\""),
        ("Ordner /Users/test.", "Ordner ~."),
        ("/Users/tester/x und /Users/test", "/Users/tester/x und ~"),
        ("/Volumes/Daten/Users/test/x", "/Volumes/Daten/Users/test/x"),
        ("Kein Pfad", "Kein Pfad"),
    ])
    func abbreviatesPathsInText(text: String, expected: String) {
        #expect(PathDisplay.abbreviatingHomePaths(in: text, home: "/Users/test/") == expected)
    }
}
