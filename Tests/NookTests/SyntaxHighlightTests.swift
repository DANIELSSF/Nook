import XCTest
@testable import Nook

final class SyntaxHighlightTests: XCTestCase {
    /// The coloured pieces of a line: what each is, in order.
    private func tokens(_ line: String, _ language: SyntaxLanguage) -> [(text: String, token: SyntaxToken)] {
        let text = line as NSString
        return SyntaxHighlighter.spans(in: line, language: language).map { (text.substring(with: $0.range), $0.token) }
    }

    private func assertToken(_ line: String, _ language: SyntaxLanguage, _ text: String, _ token: SyntaxToken?, file: StaticString = #filePath, line number: UInt = #line) {
        let found = tokens(line, language).first { $0.text == text }
        XCTAssertEqual(found?.token, token, "\(text) in \(line) as \(language): \(tokens(line, language))", file: file, line: number)
    }

    // MARK: Languages

    func testSwift() {
        let code = "    let name = \"Hola, \\(user)\" // saluda 42"
        assertToken(code, .swift, "let", .keyword)
        assertToken(code, .swift, "\"Hola, \\(user)\"", .string)
        assertToken(code, .swift, "// saluda 42", .comment)
        assertToken(code, .swift, "name", nil)
        assertToken("static func greet(name: String) -> Int {", .swift, "func", .keyword)
        assertToken("static func greet(name: String) -> Int {", .swift, "greet", .function)
        assertToken("static func greet(name: String) -> Int {", .swift, "String", .type)
        assertToken("let a = 0xFF + 1_000 + 3.5e2", .swift, "0xFF", .number)
        assertToken("let a = 0xFF + 1_000 + 3.5e2", .swift, "1_000", .number)
        assertToken("let a = 0xFF + 1_000 + 3.5e2", .swift, "3.5e2", .number)
        assertToken("@MainActor final class Model {", .swift, "@MainActor", .attribute)
        assertToken("@MainActor final class Model {", .swift, "Model", .type)
        assertToken("#if DEBUG", .swift, "#if", .attribute)
        assertToken("items.map { $0 * 2 }", .swift, "$0", .variable)
        assertToken("items.map { $0 * 2 }", .swift, "map", nil)
        assertToken("value.rounded()", .swift, "rounded", .function)
        assertToken("for i in 1...5 {", .swift, "1", .number)
        assertToken("x.default = x.class", .swift, "default", nil)
        assertToken("x.default = x.class", .swift, "class", nil)
        assertToken("let text = \"\"\"", .swift, "\"\"\"", .string)
        assertToken("    return x /* nota */ + 1", .swift, "/* nota */", .comment)
        assertToken("guard let self else { return }", .swift, "guard", .keyword)
    }

    func testJavaScriptAndTypeScript() {
        let code = "const total = await fetch(`/api/${id}`, { method: 'GET' }); // pide"
        assertToken(code, .javascript, "const", .keyword)
        assertToken(code, .javascript, "await", .keyword)
        assertToken(code, .javascript, "fetch", .function)
        assertToken(code, .javascript, "`/api/${id}`", .string)
        assertToken(code, .javascript, "'GET'", .string)
        assertToken(code, .javascript, "// pide", .comment)
        assertToken("export default function App() {", .javascript, "export", .keyword)
        assertToken("export default function App() {", .javascript, "App", .function)
        assertToken("$el.value = obj.default", .javascript, "default", nil)
        assertToken("$el.value = obj.default", .javascript, "$el", nil)
        assertToken("interface Props { name: string; count?: number }", .typescript, "interface", .keyword)
        assertToken("interface Props { name: string; count?: number }", .typescript, "Props", .type)
        assertToken("interface Props { name: string; count?: number }", .typescript, "string", .type)
        assertToken("@Component({ selector: 'x' })", .typescript, "@Component", .attribute)
        assertToken(" * @param {string} name", .javascript, "* @param {string} name", .comment)
        assertToken("  */", .javascript, "*/", .comment)
    }

    func testPython() {
        let code = "def hola(self, nombre: str = \"mundo\") -> None:  # saluda"
        assertToken(code, .python, "def", .keyword)
        assertToken(code, .python, "hola", .function)
        assertToken(code, .python, "self", .keyword)
        assertToken(code, .python, "str", .type)
        assertToken(code, .python, "\"mundo\"", .string)
        assertToken(code, .python, "None", .keyword)
        assertToken(code, .python, "# saluda", .comment)
        assertToken("@app.route('/x')", .python, "@app.route", .attribute)
        assertToken("    return f\"Hola {nombre}\" + 'x'", .python, "f\"Hola {nombre}\"", .string)
        assertToken("    \"\"\"Docstring de una línea.\"\"\"", .python, "\"\"\"Docstring de una línea.\"\"\"", .string)
        assertToken("class Gato(Animal):", .python, "Gato", .type)
        assertToken("x = [1, 2.5, 0b101]", .python, "2.5", .number)
        assertToken("# solo un comentario", .python, "# solo un comentario", .comment)
        assertToken("url = \"http://x.com/#a\"", .python, "\"http://x.com/#a\"", .string)
    }

    func testJSON() {
        let code = "  \"name\": \"Nook\", \"count\": 42, \"ok\": true, \"none\": null, \"x\": -1.5e3"
        assertToken(code, .json, "\"name\"", .variable)
        assertToken(code, .json, "\"Nook\"", .string)
        assertToken(code, .json, "42", .number)
        assertToken(code, .json, "true", .keyword)
        assertToken(code, .json, "null", .keyword)
        assertToken(code, .json, "1.5e3", .number)
        assertToken("  \"url\": \"https://x.com/a//b\"", .json, "\"https://x.com/a//b\"", .string)
    }

    func testShell() {
        let code = "git commit -m \"arregla\" && echo $HOME # fin"
        assertToken(code, .shell, "git", .function)
        assertToken(code, .shell, "commit", nil)
        assertToken(code, .shell, "-m", .attribute)
        assertToken(code, .shell, "\"arregla\"", .string)
        assertToken(code, .shell, "echo", .function)
        assertToken(code, .shell, "$HOME", .variable)
        assertToken(code, .shell, "# fin", .comment)
        assertToken("FOO=bar make test", .shell, "FOO", .variable)
        assertToken("FOO=bar make test", .shell, "make", .function)
        assertToken("if [ -f \"$x\" ]; then", .shell, "if", .keyword)
        assertToken("if [ -f \"$x\" ]; then", .shell, "then", .keyword)
        assertToken("cat a.txt | grep --color=auto 'x'", .shell, "grep", .function)
        assertToken("cat a.txt | grep --color=auto 'x'", .shell, "'x'", .string)
        assertToken("echo ${NAME:-nada}", .shell, "${NAME:-nada}", .variable)
        assertToken("echo a#b", .shell, "#b", nil)
        assertToken("# comentario", .shell, "# comentario", .comment)
    }

    func testMarkdown() {
        assertToken("## Compilar", .markdown, "## Compilar", .keyword)
        assertToken("- Escribe `Enter` para enviar", .markdown, "-", .keyword)
        assertToken("- Escribe `Enter` para enviar", .markdown, "`Enter`", .string)
        assertToken("> una cita", .markdown, "> una cita", .comment)
        assertToken("1. Primero", .markdown, "1.", .keyword)
        assertToken("```swift", .markdown, "```swift", .comment)
        assertToken("Texto normal sin nada.", .markdown, "Texto", nil)
        XCTAssertTrue(tokens("#no es un título", .markdown).isEmpty)
    }

    func testGo() {
        let code = "func (s *Server) Handle(w http.ResponseWriter, n int) error { return nil } // ok"
        assertToken(code, .go, "func", .keyword)
        assertToken(code, .go, "Server", .type)
        assertToken(code, .go, "int", .type)
        assertToken(code, .go, "error", .type)
        assertToken(code, .go, "return", .keyword)
        assertToken(code, .go, "nil", .keyword)
        assertToken(code, .go, "// ok", .comment)
        assertToken("fmt.Println(`raw`)", .go, "Println", .function)
        assertToken("fmt.Println(`raw`)", .go, "`raw`", .string)
    }

    func testRust() {
        let code = "pub fn main<'a>(x: &'a str) -> i32 { let n: u8 = 5; println!(\"hi\"); 0 } // fin"
        assertToken(code, .rust, "pub", .keyword)
        assertToken(code, .rust, "fn", .keyword)
        assertToken(code, .rust, "main", .function)
        assertToken(code, .rust, "'a", .attribute)
        assertToken(code, .rust, "str", .type)
        assertToken(code, .rust, "i32", .type)
        assertToken(code, .rust, "println", .function)
        assertToken(code, .rust, "\"hi\"", .string)
        assertToken(code, .rust, "// fin", .comment)
        assertToken("#[derive(Debug, Clone)]", .rust, "#[derive(Debug, Clone)]", .attribute)
        assertToken("let c = 'x'; let d = '\\n';", .rust, "'x'", .string)
        assertToken("let c = 'x'; let d = '\\n';", .rust, "'\\n'", .string)
        assertToken("struct Point { x: f64 }", .rust, "Point", .type)
    }

    func testRuby() {
        let code = "def hola(nombre) puts \"hi #{nombre}\" if @ok && :si # fin"
        assertToken(code, .ruby, "def", .keyword)
        assertToken(code, .ruby, "hola", .function)
        assertToken(code, .ruby, "puts", .keyword)
        assertToken(code, .ruby, "\"hi #{nombre}\"", .string)
        assertToken(code, .ruby, "@ok", .variable)
        assertToken(code, .ruby, ":si", .variable)
        assertToken(code, .ruby, "# fin", .comment)
        assertToken("class Gato < Animal", .ruby, "Gato", .type)
        assertToken("x = valid? ? 1 : 2", .ruby, "valid?", nil)
    }

    func testCFamily() {
        assertToken("#include <stdio.h>", .clike, "#include", .attribute)
        assertToken("#include <stdio.h>", .clike, "<stdio.h>", .string)
        assertToken("#define MAX 10", .clike, "#define", .attribute)
        let code = "static int main(void) { return 0; } // fin /* x */"
        assertToken(code, .clike, "static", .keyword)
        assertToken(code, .clike, "int", .type)
        assertToken(code, .clike, "void", .type)
        assertToken(code, .clike, "return", .keyword)
        assertToken(code, .clike, "main", .function)
        assertToken(code, .clike, "// fin /* x */", .comment)
        assertToken("public class Foo extends Bar implements Baz {", .clike, "class", .keyword)
        assertToken("public class Foo extends Bar implements Baz {", .clike, "Foo", .type)
        assertToken("@Override", .clike, "@Override", .attribute)
        assertToken("NSString *s = @\"hola\";", .clike, "@\"hola\"", .string)
        assertToken("char c = 'x'; /* nota */ int y;", .clike, "/* nota */", .comment)
        assertToken("x = 12px + 0.5f + 10UL", .clike, "0.5f", .number)
    }

    func testYAMLAndTOML() {
        assertToken("name: nook # app", .yaml, "name", .variable)
        assertToken("name: nook # app", .yaml, "# app", .comment)
        assertToken("  - enabled: true", .yaml, "enabled", .variable)
        assertToken("  - enabled: true", .yaml, "true", .keyword)
        assertToken("port: 8080", .yaml, "8080", .number)
        assertToken("url: \"http://x\"", .yaml, "\"http://x\"", .string)
        assertToken("[package]", .yaml, "[package]", .type)
        assertToken("version = \"1.0\"", .yaml, "version", .variable)
        assertToken("image: nginx:latest", .yaml, "image", .variable)
        assertToken("image: nginx:latest", .yaml, "nginx", nil)
    }

    func testCSSAndHTML() {
        let css = ".btn:hover { color: #fff; margin: 0 auto; width: 12px; /* c */ }"
        assertToken(css, .css, ".btn", .type)
        assertToken(css, .css, "#fff", .number)
        assertToken(css, .css, "12px", .number)
        assertToken(css, .css, "/* c */", .comment)
        assertToken("  color: red;", .css, "color", .variable)
        assertToken("@media (max-width: 600px) {", .css, "600px", .number)
        let html = "<div class=\"card\" data-x='1'>Hola</div> <!-- fin -->"
        assertToken(html, .html, "<div", .keyword)
        assertToken(html, .html, "class", .attribute)
        assertToken(html, .html, "\"card\"", .string)
        assertToken(html, .html, "</div", .keyword)
        assertToken(html, .html, "<!-- fin -->", .comment)
        assertToken("if (a < b) {}", .html, "<", nil)
    }

    func testDiffBlocks() {
        assertToken("+let a = 1", .diff, "+let a = 1", .inserted)
        assertToken("-let a = 0", .diff, "-let a = 0", .deleted)
        assertToken("+++ b/Sources/A.swift", .diff, "+++ b/Sources/A.swift", .keyword)
        assertToken("@@ -1,3 +1,4 @@", .diff, "@@ -1,3 +1,4 @@", .attribute)
        XCTAssertTrue(tokens(" contexto", .diff).isEmpty)
    }

    // MARK: Robustness

    func testSpansAreUTF16RangesOfTheLineAndNeverOverlap() {
        let line = "let café = \"héllo 🐈 mundo\" // ñandú 🐕 ok"
        let text = line as NSString
        let spans = SyntaxHighlighter.spans(in: line, language: .swift)
        XCTAssertEqual(spans.map { text.substring(with: $0.range) }, ["let", "\"héllo 🐈 mundo\"", "// ñandú 🐕 ok"])
        // In a range of a longer text, the spans are in that text's coordinates.
        let whole = "primera\n" + line + "\nultima" as NSString
        let start = whole.range(of: line)
        let inside = SyntaxHighlighter.spans(in: whole, range: start, language: .swift)
        XCTAssertEqual(inside.map { whole.substring(with: $0.range) }, ["let", "\"héllo 🐈 mundo\"", "// ñandú 🐕 ok"])
    }

    func testAnyJunkInAnyLanguageGivesOrderedSpansInsideTheLine() {
        let pieces = ["let", "\"", "'", "`", "//", "/*", "*/", "#", "@", "$", "{", "}", "(", ")", "[", "]", "0x", "1.", ".5", "é", "🐈", " ", "  ", "\\", "<", ">", "<!--", "-->", "```", "\"\"\"", ":", "=", "-", "+", "'a", "#[", "\n", "func", "def", "if", "if [", "$(", "${", "&&", "|", ";", "ABC", "x1", "..."]
        var state: UInt64 = 0xC0DE
        func next(_ limit: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(limit)) }
        for language in SyntaxLanguage.allCases {
            for _ in 0..<400 {
                let line = (0..<(1 + next(14))).map { _ in pieces[next(pieces.count)] }.joined()
                let length = (line as NSString).length
                var end = 0
                for span in SyntaxHighlighter.spans(in: line, language: language) {
                    XCTAssertGreaterThanOrEqual(span.range.location, end, "\(language): \(line.debugDescription) overlaps")
                    XCTAssertGreaterThan(span.range.length, 0, "\(language): \(line.debugDescription)")
                    XCTAssertLessThanOrEqual(NSMaxRange(span.range), length, "\(language): \(line.debugDescription)")
                    end = NSMaxRange(span.range)
                }
            }
        }
    }

    func testAVeryLongLineIsOnlyColouredUpToTheLimit() {
        let long = String(repeating: "let a = 1; ", count: 2000)
        let spans = SyntaxHighlighter.spans(in: long, language: .swift)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertLessThanOrEqual(spans.map { NSMaxRange($0.range) }.max() ?? 0, SyntaxHighlighter.maxLineLength)
        XCTAssertTrue(SyntaxHighlighter.spans(in: "", language: .swift).isEmpty)
    }

    func testColouringALongFileIsFast() {
        let code = (0..<2000).map { "    static func item\($0)(name: String, value: Int = \($0)) -> Bool { return value > 0x1F /* nota */ } // fin \($0)" }
        let text = code.joined(separator: "\n") as NSString
        let started = Date()
        var total = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { _, range, _, _ in
            total += SyntaxHighlighter.spans(in: text, range: range, language: .swift).count
        }
        let seconds = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(total, 2000 * 8)
        XCTAssertLessThan(seconds, 0.5, "\(text.length) characters took \(seconds) s.")
    }

    // MARK: Which language

    func testTheLanguageComesFromTheFilesExtension() {
        let cases: [(String, SyntaxLanguage?)] = [
            ("Sources/Notch.swift", .swift), ("a/b.JS", .javascript), ("x.tsx", .typescript), ("tool.py", .python), ("package.json", .json), ("run.sh", .shell),
            ("README.md", .markdown), ("main.go", .go), ("lib.rs", .rust), ("app.rb", .ruby), ("a.h", .clike), ("A.java", .clike), ("deploy.yml", .yaml),
            ("site.css", .css), ("index.html", .html), ("x.patch", .diff), ("Dockerfile", .shell), ("Gemfile", .ruby), ("noextension", nil), ("image.png", nil), ("", nil),
        ]
        for (path, expected) in cases { XCTAssertEqual(SyntaxLanguage.forPath(path), expected, path) }
    }

    func testTheLanguageComesFromAFencesName() {
        let cases: [(String, SyntaxLanguage?)] = [
            ("swift", .swift), ("Swift", .swift), (" js ", .javascript), ("typescript", .typescript), ("py", .python), ("json", .json), ("bash", .shell), ("zsh", .shell),
            ("md", .markdown), ("go", .go), ("rust", .rust), ("ruby", .ruby), ("c++", .clike), ("objc", .clike), ("yaml", .yaml), ("css", .css), ("html", .html),
            ("diff", .diff), ("swift title=\"A.swift\"", .swift), ("{.python}", .python), ("", nil), ("brainfuck", nil), ("text", nil),
        ]
        for (name, expected) in cases { XCTAssertEqual(SyntaxLanguage.forFence(name), expected, name) }
    }
}
