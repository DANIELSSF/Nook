import Foundation

// A small, cheap syntax highlighter for the mirror: the code of a change's rows (the lines Claude edited or wrote) and
// the fenced blocks of Claude's replies. It colours keywords, strings, numbers, comments, types, calls, attributes and
// variables; it never judges whether the code is valid and never changes a character.
//
// One pass over the line's UTF-16 units, no regular expressions, no state between lines: a change row is shown without
// the lines around it, so each line has to stand alone. What spans lines (a block comment's middle, a docstring) is
// recognised only by its shape on that line (a line that starts with "*" inside a comment, for example).
//
// Everything is anchored to the language: `SyntaxLanguage.forPath` reads a file's extension, `forFence` a fence's name.

/// What a stretch of code is, for colouring.
enum SyntaxToken: UInt8, CaseIterable {
    case keyword, string, number, comment, type, function, attribute, variable
    /// Lines of a `diff` block: added and removed.
    case inserted, deleted
}

enum SyntaxLanguage: String, CaseIterable {
    case swift, javascript, typescript, python, json, shell, markdown, go, rust, ruby
    /// C, C++, Objective-C, Java, C# and Kotlin share one grammar: the union of their keywords.
    case clike
    case yaml, css, html, diff

    /// The language of a file by its extension; nil when it is not one the highlighter knows.
    static func forPath(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if ext.isEmpty {
            switch name {
            case "dockerfile", "makefile": return .shell
            case ".zshrc", ".bashrc", ".zprofile", ".bash_profile", ".profile": return .shell
            case "gemfile", "rakefile", "podfile", "fastfile": return .ruby
            default: return nil
            }
        }
        switch ext {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyw", "pyi": return .python
        case "json", "jsonc", "json5": return .json
        case "sh", "bash", "zsh", "command": return .shell
        case "md", "markdown", "mdx": return .markdown
        case "go": return .go
        case "rs": return .rust
        case "rb", "rake", "gemspec", "erb": return .ruby
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "java", "cs", "kt", "kts", "scala", "dart": return .clike
        case "yaml", "yml", "toml": return .yaml
        case "css", "scss", "less": return .css
        case "html", "htm", "xml", "svg", "plist", "vue": return .html
        case "diff", "patch": return .diff
        default: return nil
        }
    }

    /// The language a Markdown fence names (```swift, ```ts…); nil when it names none or an unknown one.
    static func forFence(_ info: String) -> SyntaxLanguage? {
        // "swift", "swift title=…", "{.python}", "js:app.js": the first word, without braces or a leading dot.
        var name = info.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" || $0 == "," || $0 == ":" }).first.map(String.init) ?? ""
        if name.hasPrefix(".") { name.removeFirst() }
        switch name {
        case "swift": return .swift
        case "js", "javascript", "jsx", "node", "mjs": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "py", "python", "python3": return .python
        case "json", "jsonc", "json5": return .json
        case "sh", "bash", "shell", "zsh", "console", "terminal", "shellscript", "fish": return .shell
        case "md", "markdown": return .markdown
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "rb", "ruby": return .ruby
        case "c", "h", "cpp", "c++", "cc", "objc", "objective-c", "objectivec", "java", "cs", "csharp", "c#", "kotlin", "kt", "scala", "dart": return .clike
        case "yaml", "yml", "toml": return .yaml
        case "css", "scss", "less": return .css
        case "html", "xml", "svg", "vue": return .html
        case "diff", "patch": return .diff
        default: return nil
        }
    }
}

enum SyntaxHighlighter {
    struct Span: Equatable {
        var range: NSRange
        var token: SyntaxToken
    }

    /// Longest part of a line that is coloured; a minified line of 100,000 characters keeps its look past this.
    static let maxLineLength = 4000

    /// The coloured spans of `range` of `text` read as one line of `language`, in order and without overlaps. Plain
    /// code (names, punctuation, spaces) has no span.
    static func spans(in text: NSString, range: NSRange, language: SyntaxLanguage) -> [Span] {
        let length = min(range.length, maxLineLength)
        guard length > 0, range.location >= 0, NSMaxRange(range) <= text.length else { return [] }
        var chars = [unichar](repeating: 0, count: length)
        text.getCharacters(&chars, range: NSRange(location: range.location, length: length))
        var lexer = Lexer(c: chars, language: language)
        lexer.run()
        return lexer.spans.map { Span(range: NSRange(location: range.location + $0.start, length: $0.end - $0.start), token: $0.token) }
    }

    /// The same for a plain string (tests, previews).
    static func spans(in line: String, language: SyntaxLanguage) -> [Span] {
        spans(in: line as NSString, range: NSRange(location: 0, length: (line as NSString).length), language: language)
    }
}

// MARK: - Grammar

private struct Grammar {
    var keywords: Set<String>
    /// Lowercase type names the language ships (`int`, `string`, `usize`).
    var types: Set<String> = []
    var lineComment: [[unichar]] = []
    var blockComments = false
    var quotes: [unichar] = []
    /// A word that starts with a capital is a type (or a constant).
    var capitalTypes = true
    /// Words after these are named things: a function, or a type.
    var functionIntroducers: Set<String> = []
    var typeIntroducers: Set<String> = []
}

private func units(_ text: String) -> [unichar] { Array(text.utf16) }
private func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

private enum Grammars {
    static let swift = Grammar(
        keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while Any as await false is nil self Self super throws true try async actor some any final lazy mutating nonmutating override weak unowned required convenience optional indirect get set willSet didSet dynamic nonisolated isolated consuming borrowing macro"),
        lineComment: [units("//")], blockComments: true, quotes: [0x22],
        functionIntroducers: words("func"), typeIntroducers: words("class struct enum protocol extension typealias actor associatedtype"))
    static let script = Grammar(
        keywords: words("async await break case catch class const continue debugger default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null package private protected public return static super switch this throw true try typeof undefined var void while with yield as abstract readonly keyof infer satisfies"),
        types: words("string number boolean any unknown never object symbol bigint"),
        lineComment: [units("//")], blockComments: true, quotes: [0x22, 0x27, 0x60],
        functionIntroducers: words("function"), typeIntroducers: words("class interface enum"))
    static let python = Grammar(
        keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case self cls"),
        types: words("int str float bool list dict set tuple bytes object type frozenset complex bytearray"),
        lineComment: [units("#")], quotes: [0x22, 0x27],
        functionIntroducers: words("def"), typeIntroducers: words("class"))
    static let json = Grammar(keywords: words("true false null"), lineComment: [units("//")], quotes: [0x22], capitalTypes: false)
    static let go = Grammar(
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota"),
        types: words("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr float32 float64 complex64 complex128 string bool byte rune error any"),
        lineComment: [units("//")], blockComments: true, quotes: [0x22, 0x27, 0x60],
        functionIntroducers: words("func"), typeIntroducers: words("type"))
    static let rust = Grammar(
        keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        lineComment: [units("//")], blockComments: true, quotes: [0x22, 0x27],
        functionIntroducers: words("fn"), typeIntroducers: words("struct enum trait impl type mod"))
    static let ruby = Grammar(
        keywords: words("alias and begin break case class def do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative include extend attr_accessor attr_reader attr_writer puts raise lambda proc private public protected"),
        lineComment: [units("#")], quotes: [0x22, 0x27, 0x60],
        functionIntroducers: words("def"), typeIntroducers: words("class module"))
    static let clike = Grammar(
        keywords: words("auto break case class const constexpr continue default delete do else enum explicit extern false final for friend goto if inline namespace new noexcept nullptr operator override private protected public register return sizeof static struct switch template this throw true try typedef typename union using virtual volatile while import package interface implements extends abstract synchronized throws instanceof null super var val fun when object companion data sealed internal lateinit readonly foreach in is as out ref params get set"),
        types: words("int long short char float double void bool boolean byte unsigned signed size_t ssize_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t string"),
        lineComment: [units("//")], blockComments: true, quotes: [0x22, 0x27],
        functionIntroducers: words("fun"), typeIntroducers: words("class struct enum interface namespace union object"))
    static let yaml = Grammar(keywords: words("true false null yes no on off True False Null"), lineComment: [units("#")], quotes: [0x22, 0x27], capitalTypes: false)
    static let css = Grammar(keywords: words("important"), blockComments: true, quotes: [0x22, 0x27], capitalTypes: false)

    static func grammar(for language: SyntaxLanguage) -> Grammar {
        switch language {
        case .swift: swift
        case .javascript, .typescript: script
        case .python: python
        case .json: json
        case .go: go
        case .rust: rust
        case .ruby: ruby
        case .clike: clike
        case .yaml: yaml
        case .css: css
        case .shell, .markdown, .html, .diff: Grammar(keywords: [], capitalTypes: false)
        }
    }

    static let shellKeywords = words("if then else elif fi for while until do done case esac in function select time return exit break continue export local readonly declare unset source alias set trap eval exec")
}

// MARK: - Lexer

private struct Lexer {
    let c: [unichar]
    let n: Int
    let language: SyntaxLanguage
    let grammar: Grammar
    var spans: [(start: Int, end: Int, token: SyntaxToken)] = []
    var i = 0
    /// The word just before, when only spaces lie between it and the position (`func` before a name).
    var lastWord: String?

    init(c: [unichar], language: SyntaxLanguage) {
        self.c = c; n = c.count; self.language = language
        grammar = Grammars.grammar(for: language)
    }

    mutating func run() {
        switch language {
        case .diff: diff()
        case .markdown: markdown()
        case .shell: shell()
        case .html: html()
        default: generic()
        }
    }

    // MARK: Characters

    private static let space: unichar = 0x20
    private func isSpace(_ ch: unichar) -> Bool { ch == 0x20 || ch == 0x09 || ch == 0xA0 || ch == 0x0D }
    private func isDigit(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }
    private func isUpper(_ ch: unichar) -> Bool { ch >= 0x41 && ch <= 0x5A }
    private func isLetter(_ ch: unichar) -> Bool { (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch > 0x7F }
    private func isHex(_ ch: unichar) -> Bool { isDigit(ch) || (ch >= 0x41 && ch <= 0x46) || (ch >= 0x61 && ch <= 0x66) }
    private func isIdentStart(_ ch: unichar) -> Bool {
        isLetter(ch) || ch == 0x5F || (ch == 0x24 && (language == .javascript || language == .typescript))
    }
    private func isIdentChar(_ ch: unichar) -> Bool {
        isIdentStart(ch) || isDigit(ch) || ((language == .yaml || language == .css) && (ch == 0x2D || (ch == 0x2E && language == .yaml)))
    }
    private func at(_ index: Int) -> unichar { index >= 0 && index < n ? c[index] : 0 }
    private func hasPrefix(_ prefix: [unichar], at index: Int) -> Bool {
        guard index + prefix.count <= n else { return false }
        for (offset, unit) in prefix.enumerated() where c[index + offset] != unit { return false }
        return true
    }
    private func word(_ start: Int, _ end: Int) -> String { String(decoding: c[start..<end], as: UTF16.self) }
    private func nextNonSpace(from index: Int) -> unichar {
        var j = index
        while j < n, isSpace(c[j]) { j += 1 }
        return at(j)
    }
    private mutating func emit(_ start: Int, _ end: Int, _ token: SyntaxToken) {
        guard end > start else { return }
        spans.append((start, end, token))
    }

    // MARK: Generic grammar (C-like, scripting languages, JSON, YAML, CSS)

    private mutating func generic() {
        var lead = 0
        while lead < n, isSpace(c[lead]) { lead += 1 }
        // The middle of a block comment, as JSDoc and Javadoc draw it: a line that starts with "*".
        if grammar.blockComments, lead < n, c[lead] == 0x2A, lead + 1 == n || c[lead + 1] == 0x20 || c[lead + 1] == 0x2F {
            emit(lead, n, .comment); return
        }
        if language == .yaml, lead < n, c[lead] == 0x5B { emit(lead, n, .type); return }   // TOML [section]
        if language == .python, lead < n, c[lead] == 0x40, lead + 1 < n, isIdentStart(c[lead + 1]) { decorator(); }
        while i < n {
            let ch = c[i]
            if isSpace(ch) { i += 1; continue }
            if grammar.lineComment.contains(where: { hasPrefix($0, at: i) }) && (language != .yaml || i == 0 || isSpace(c[i - 1])) {
                emit(i, n, .comment); return
            }
            if grammar.blockComments, ch == 0x2F, at(i + 1) == 0x2A {
                var j = i + 2
                while j + 1 < n, !(c[j] == 0x2A && c[j + 1] == 0x2F) { j += 1 }
                let end = j + 1 < n ? j + 2 : n
                emit(i, end, .comment); i = end; lastWord = nil; continue
            }
            if grammar.quotes.contains(ch) { quoted(ch); lastWord = nil; continue }
            if isDigit(ch) || (ch == 0x2E && isDigit(at(i + 1)) && !isIdentChar(at(i - 1)) && at(i - 1) != 0x29) { number(); lastWord = nil; continue }
            if ch == 0x40 { at_sign(); continue }
            if ch == 0x23 { hash(); continue }
            if ch == 0x24 && !isIdentStart(ch) { dollar(); continue }
            if language == .css && ch == 0x2E && isLetter(at(i + 1)) {
                var j = i + 1
                while j < n, isIdentChar(c[j]) { j += 1 }
                emit(i, j, .type); i = j; lastWord = nil; continue
            }
            if language == .ruby && ch == 0x3A && isLetter(at(i + 1)) && at(i - 1) != 0x3A {
                var j = i + 1
                while j < n, isIdentChar(c[j]) || c[j] == 0x3F || c[j] == 0x21 { j += 1 }
                emit(i, j, .variable); i = j; lastWord = nil; continue
            }
            if isIdentStart(ch) { identifier(); continue }
            lastWord = nil
            i += 1
        }
    }

    private mutating func decorator() {
        var j = i
        while j < n, isSpace(c[j]) { j += 1 }
        let start = j
        j += 1
        while j < n, isIdentChar(c[j]) || c[j] == 0x2E { j += 1 }
        emit(start, j, .attribute); i = j
    }

    private mutating func quoted(_ quote: unichar) {
        let start = i
        // Rust: 'a is a lifetime, 'a' is a character.
        if language == .rust, quote == 0x27, isIdentStart(at(i + 1)), at(i + 2) != 0x27 {
            var j = i + 1
            while j < n, isIdentChar(c[j]) { j += 1 }
            emit(start, j, .attribute); i = j; return
        }
        // Triple quotes: Python docstrings, Swift multi-line strings (a line holds the start, the end or both).
        if (language == .python || language == .swift), at(i + 1) == quote, at(i + 2) == quote {
            var j = i + 3
            while j + 2 < n, !(c[j] == quote && c[j + 1] == quote && c[j + 2] == quote) { j += 1 }
            let end = j + 2 < n ? j + 3 : n
            emit(start, end, .string); i = end; return
        }
        var j = i + 1
        while j < n {
            if c[j] == 0x5C { j += 2; continue }
            if c[j] == quote { j += 1; break }
            j += 1
        }
        let end = min(j, n)
        // A JSON string followed by a colon is a key.
        let token: SyntaxToken = language == .json && nextNonSpace(from: end) == 0x3A ? .variable : .string
        emit(start, end, token)
        i = end
    }

    private mutating func number() {
        let start = i
        var j = i
        if c[j] == 0x30, j + 1 < n, [0x78, 0x58, 0x62, 0x42, 0x6F, 0x4F].contains(c[j + 1]) {
            j += 2
            while j < n, isHex(c[j]) || c[j] == 0x5F { j += 1 }
        } else {
            while j < n {
                let ch = c[j]
                if isDigit(ch) || ch == 0x5F { j += 1 }
                else if ch == 0x2E, isDigit(at(j + 1)) { j += 1 }
                else if (ch == 0x65 || ch == 0x45), isDigit(at(j + 1)) || ((at(j + 1) == 0x2B || at(j + 1) == 0x2D) && isDigit(at(j + 2))) { j += 2 }
                else { break }
            }
        }
        // A unit or suffix glued to the number (12px, 3.5f, 10u64, 5L).
        while j < n, isLetter(c[j]) || c[j] == 0x25 || c[j] == 0x5F || isDigit(c[j]) { j += 1 }
        emit(start, j, .number)
        i = j
    }

    private mutating func at_sign() {
        let start = i
        var j = i + 1
        // Objective-C string literal: @"text".
        if at(j) == 0x22, language == .clike {
            i = j; quoted(0x22); lastWord = nil
            if let last = spans.last, last.start == j { spans[spans.count - 1].start = start }
            return
        }
        guard isIdentStart(at(j)) || at(j) == 0x40 else { i += 1; lastWord = nil; return }
        while j < n, c[j] == 0x40 { j += 1 }
        let nameStart = j
        while j < n, isIdentChar(c[j]) || (language == .python && c[j] == 0x2E) { j += 1 }
        guard j > nameStart else { i = j; return }
        emit(start, j, language == .ruby ? .variable : .attribute)
        i = j; lastWord = nil
    }

    private mutating func hash() {
        let start = i
        switch language {
        case .swift, .clike:
            // #if, #available, #include, #define: the directive; an #include's file is a string.
            var j = i + 1
            while j < n, isLetter(c[j]) { j += 1 }
            guard j > i + 1 else { i += 1; return }
            emit(start, j, .attribute)
            let name = word(start + 1, j)
            i = j
            if name == "include" || name == "import" {
                var k = j
                while k < n, isSpace(c[k]) { k += 1 }
                if at(k) == 0x3C {
                    var e = k + 1
                    while e < n, c[e] != 0x3E { e += 1 }
                    emit(k, min(e + 1, n), .string); i = min(e + 1, n)
                }
            }
        case .rust:
            // #[derive(Debug)] and #![allow(…)]: the whole attribute.
            var j = i + 1
            if at(j) == 0x21 { j += 1 }
            guard at(j) == 0x5B else { i += 1; return }
            while j < n, c[j] != 0x5D { j += 1 }
            let end = min(j + 1, n)
            emit(start, end, .attribute); i = end
        case .css:
            var j = i + 1
            while j < n, isHex(c[j]) { j += 1 }
            let hexLength = j - i - 1
            if [3, 4, 6, 8].contains(hexLength), !isIdentChar(at(j)) { emit(start, j, .number); i = j }
            else {
                j = i + 1
                while j < n, isIdentChar(c[j]) { j += 1 }
                emit(start, j, .type); i = max(j, i + 1)
            }
        default:
            i += 1
        }
        lastWord = nil
    }

    private mutating func dollar() {
        // Swift's $0 and $name, Ruby's $stdout: a variable.
        var j = i + 1
        guard isLetter(at(j)) || isDigit(at(j)) || at(j) == 0x5F else { i += 1; return }
        while j < n, isIdentChar(c[j]) { j += 1 }
        emit(i, j, .variable); i = j; lastWord = nil
    }

    private mutating func identifier() {
        let start = i
        var j = i + 1
        while j < n, isIdentChar(c[j]) { j += 1 }
        if language == .ruby, j < n, c[j] == 0x3F || c[j] == 0x21, at(j + 1) != 0x3D { j += 1 }
        let text = word(start, j)
        // A prefixed string: f"…", r'…', b"…", rb"…".
        if (language == .python || language == .ruby), j < n, (c[j] == 0x22 || c[j] == 0x27), j - start <= 2,
           text.lowercased().allSatisfy({ "rbfu".contains($0) }) {
            i = j
            quoted(c[j])
            if let last = spans.last, last.start == j { spans[spans.count - 1].start = start }
            lastWord = nil
            return
        }
        i = j
        let afterDot = start > 0 && c[start - 1] == 0x2E && at(start - 2) != 0x2E
        let called = at(j) == 0x28 || (language == .rust && at(j) == 0x21 && [0x28, 0x5B, 0x7B].contains(at(j + 1)))
        defer { lastWord = text }
        // A key in YAML or TOML.
        if language == .yaml, !afterDot {
            let next = at(j)
            if (next == 0x3A && (j + 1 >= n || isSpace(c[j + 1]))) || nextNonSpace(from: j) == 0x3D { emit(start, j, .variable); return }
        }
        // CSS: a property before its colon.
        if language == .css, at(j) == 0x3A, at(j + 1) != 0x3A, isDeclaration(start) {
            emit(start, j, .variable); return
        }
        if afterDot {
            if called { emit(start, j, .function) }
            return
        }
        // `lastWord` is cleared by everything but spaces, so it is the word right before this one.
        if let previous = lastWord {
            if grammar.functionIntroducers.contains(previous), !grammar.keywords.contains(text) { emit(start, j, .function); return }
            if grammar.typeIntroducers.contains(previous), !grammar.keywords.contains(text) { emit(start, j, .type); return }
        }
        if grammar.keywords.contains(text) { emit(start, j, .keyword); return }
        if grammar.types.contains(text) { emit(start, j, .type); return }
        if grammar.capitalTypes, isUpper(c[start]) {
            // Go's exported functions are called with a capital.
            emit(start, j, language == .go && called ? .function : .type); return
        }
        if called { emit(start, j, .function) }
    }

    /// CSS: the line holds a property when no "{" opens before it that is not closed (a rule's first line `a:hover {`
    /// is a selector, a declaration has its colon before any brace).
    private func isDeclaration(_ start: Int) -> Bool {
        for k in start..<n where c[k] == 0x7B { return false }
        return true
    }

    // MARK: Shell

    private mutating func shell() {
        var command = true
        while i < n {
            let ch = c[i]
            if isSpace(ch) { i += 1; continue }
            if ch == 0x23, i == 0 || isSpace(c[i - 1]) { emit(i, n, .comment); return }
            if ch == 0x22 || ch == 0x27 || ch == 0x60 {
                let start = i
                var j = i + 1
                while j < n {
                    if c[j] == 0x5C, ch != 0x27 { j += 2; continue }
                    if c[j] == ch { j += 1; break }
                    j += 1
                }
                let end = min(j, n)
                emit(start, end, .string); i = end; command = false; continue
            }
            if ch == 0x24 {
                var j = i + 1
                if at(j) == 0x7B { while j < n, c[j] != 0x7D { j += 1 }; j = min(j + 1, n) }
                else if at(j) == 0x28 { i += 1; command = true; continue }
                else if isLetter(at(j)) || at(j) == 0x5F { while j < n, isLetter(c[j]) || isDigit(c[j]) || c[j] == 0x5F { j += 1 } }
                else if j < n { j += 1 }
                emit(i, j, .variable); i = j; command = false; continue
            }
            if ch == 0x7C || ch == 0x3B || ch == 0x26 || ch == 0x28 || ch == 0x7B { i += 1; command = true; continue }
            if ch == 0x3E || ch == 0x3C || ch == 0x29 || ch == 0x7D { i += 1; continue }
            // A word: up to a space or an operator.
            let start = i
            var j = i
            while j < n, !isSpace(c[j]), ![0x7C, 0x3B, 0x26, 0x3C, 0x3E, 0x28, 0x29, 0x22, 0x27, 0x60, 0x24].contains(c[j]) { j += 1 }
            if j == start { i += 1; continue }
            let text = word(start, j)
            i = j
            if Grammars.shellKeywords.contains(text) {
                emit(start, j, .keyword)
                command = ["then", "else", "do", "elif", "if", "while", "until", "time"].contains(text)
            } else if let equals = text.firstIndex(of: "="), equals != text.startIndex, text[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                emit(start, start + text[..<equals].utf16.count, .variable)
            } else if text.hasPrefix("-"), text.count > 1 {
                emit(start, j, .attribute); command = false
            } else if command {
                emit(start, j, .function); command = false
            } else if text.allSatisfy({ $0.isNumber }) {
                emit(start, j, .number)
            } else { command = false }
        }
    }

    // MARK: Markdown

    private mutating func markdown() {
        var lead = 0
        while lead < n, isSpace(c[lead]) { lead += 1 }
        guard lead < n else { return }
        if c[lead] == 0x23 {
            var j = lead
            while j < n, c[j] == 0x23 { j += 1 }
            if j - lead <= 6, j == n || isSpace(c[j]) { emit(lead, n, .keyword); return }
        }
        if c[lead] == 0x3E { emit(lead, n, .comment); return }
        if hasPrefix(units("```"), at: lead) { emit(lead, n, .comment); return }
        // List markers: "- ", "* ", "+ ", "1. ".
        if [0x2D, 0x2A, 0x2B].contains(c[lead]), isSpace(at(lead + 1)) { emit(lead, lead + 1, .keyword); i = lead + 1 }
        else if isDigit(c[lead]) {
            var j = lead
            while j < n, isDigit(c[j]) { j += 1 }
            if at(j) == 0x2E, isSpace(at(j + 1)) { emit(lead, j + 1, .keyword); i = j + 1 }
        }
        // Inline code.
        while i < n {
            if c[i] == 0x60 {
                var j = i + 1
                while j < n, c[j] != 0x60 { j += 1 }
                let end = min(j + 1, n)
                emit(i, end, .string); i = end
            } else { i += 1 }
        }
    }

    // MARK: Diff

    private mutating func diff() {
        guard n > 0 else { return }
        switch c[0] {
        case 0x2B: emit(0, n, hasPrefix(units("+++"), at: 0) ? .keyword : .inserted)
        case 0x2D: emit(0, n, hasPrefix(units("---"), at: 0) ? .keyword : .deleted)
        case 0x40: emit(0, n, .attribute)
        default:
            if hasPrefix(units("diff "), at: 0) || hasPrefix(units("index "), at: 0) { emit(0, n, .keyword) }
        }
    }

    // MARK: HTML and XML

    private mutating func html() {
        while i < n {
            if hasPrefix(units("<!--"), at: i) {
                var j = i + 4
                while j + 2 < n, !(c[j] == 0x2D && c[j + 1] == 0x2D && c[j + 2] == 0x3E) { j += 1 }
                let end = j + 2 < n ? j + 3 : n
                emit(i, end, .comment); i = end; continue
            }
            guard c[i] == 0x3C, i + 1 < n, isLetter(c[i + 1]) || c[i + 1] == 0x2F || c[i + 1] == 0x21 || c[i + 1] == 0x3F else { i += 1; continue }
            // The tag's name.
            var j = i + 1
            if c[j] == 0x2F || c[j] == 0x21 || c[j] == 0x3F { j += 1 }
            while j < n, isLetter(c[j]) || isDigit(c[j]) || c[j] == 0x2D || c[j] == 0x3A || c[j] == 0x5F || c[j] == 0x2E { j += 1 }
            emit(i, j, .keyword)
            i = j
            // Its attributes, up to the closing ">".
            while i < n, c[i] != 0x3E {
                let ch = c[i]
                if ch == 0x22 || ch == 0x27 {
                    var k = i + 1
                    while k < n, c[k] != ch { k += 1 }
                    let end = min(k + 1, n)
                    emit(i, end, .string); i = end
                } else if isLetter(ch) || ch == 0x40 || ch == 0x3A || ch == 0x5F {
                    var k = i + 1
                    while k < n, isLetter(c[k]) || isDigit(c[k]) || c[k] == 0x2D || c[k] == 0x3A || c[k] == 0x5F || c[k] == 0x2E { k += 1 }
                    emit(i, k, .attribute); i = k
                } else { i += 1 }
            }
        }
    }
}
