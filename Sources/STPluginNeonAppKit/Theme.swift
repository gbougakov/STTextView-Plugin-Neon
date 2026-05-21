import Cocoa

public struct Theme {
    
    // MARK: - Props
    public let colors: Colors
    public let fonts: Fonts

    // MARK: - Lifecycle
    public init(colors: Colors, fonts: Fonts) {
        self.colors = colors
        self.fonts = fonts
    }
    
    public func color(forToken tokenName: TokenName) -> NSColor? {
        colors.color(forToken: tokenName)
    }
    
    public func font(forToken tokenName: TokenName) -> NSFont? {
        fonts.font(forToken: tokenName)
    }

    public struct Colors {
        
        public let colors: [TokenName: NSColor]

        public init(colors: [String: NSColor]) {
            self.colors = Dictionary(uniqueKeysWithValues: colors.map { key, value in (TokenName(key), value) })
        }

        public init(bundle: Bundle, name: String) {
            let load: (String) -> NSColor = { token in
                NSColor(named: "\(name)/\(token)", bundle: bundle)!
            }
            let plain = load("plain")
            let keyword = load("keyword")
            let comment = load("comment")
            let punctSpecial = load("punctuation.special")
            let keywordFunction = load("keyword.function")

            colors = [
                "plain": plain,
                "boolean": load("boolean"),
                "comment": comment,
                "constructor": load("constructor"),
                "function.call": load("function.call"),
                "include": load("include"),
                "keyword": keyword,
                "keyword.function": keywordFunction,
                "keyword.return": load("keyword.return"),
                "method": load("method"),
                "number": load("number"),
                "operator": load("operator"),
                "parameter": load("parameter"),
                "punctuation.special": punctSpecial,
                "string": load("string"),
                "text.literal": load("text.literal"),
                "text.title": load("text.title"),
                "type": load("type"),
                "variable.builtin": load("variable.builtin"),
                "variable": load("variable"),
                // Markdown inline aliases — no dedicated colorset (yet); reuse
                // existing palette entries so the default theme styles
                // emphasis/strong/links/escapes/delimiters out of the box.
                // Override by constructing a custom Theme with new colors.
                "text.strong": plain,            // bold weight carries the styling, color unchanged
                "text.emphasis": plain,          // italic carries the styling
                "text.reference": keyword,       // link text
                "text.uri": keywordFunction,     // URLs
                "punctuation.delimiter": comment,// dim out *, **, [, ], (, )
                "string.escape": punctSpecial    // \* etc.
            ]
        }
        
        public func color(forToken tokenName: TokenName) -> NSColor? {
            colors[tokenName]
        }
    }

    public struct Fonts {

        public let fonts: [TokenName: NSFont]

        public init(fonts: [String: NSFont]) {
            self.fonts = Dictionary(uniqueKeysWithValues: fonts.map { key, value in (TokenName(key), value) })
        }

        public init(bundle: Bundle, name: String) {
            let regular = NSFont.monospacedSystemFont(ofSize: 0, weight: .regular)
            let medium = NSFont.monospacedSystemFont(ofSize: 0, weight: .medium)
            let bold = NSFont.monospacedSystemFont(ofSize: 0, weight: .bold)
            // SF Mono Italic exists on macOS 13+; fall back to regular if the
            // descriptor can't find an italic variant for the current system
            // font. (Italic emphasis still gets `text.emphasis` color even
            // without an italic face, so it stays visually distinguishable.)
            let italic: NSFont = {
                let italicDescriptor = regular.fontDescriptor.withSymbolicTraits(.italic)
                return NSFont(descriptor: italicDescriptor, size: 0) ?? regular
            }()

            fonts = [
                "plain": regular,
                "boolean": regular,
                "comment": regular,
                "constructor": medium,
                "function.call": regular,
                "include": regular,
                "keyword": medium,
                "keyword.function": medium,
                "keyword.return": medium,
                "method": regular,
                "number": regular,
                "operator": regular,
                "parameter": regular,
                "punctuation.special": regular,
                "string": regular,
                "text.literal": regular,
                "text.title": medium,
                "type": regular,
                "variable.builtin": regular,
                "variable": regular,
                // Markdown inline emphasis — bold/italic faces.
                "text.strong": bold,
                "text.emphasis": italic,
                "text.reference": regular,
                "text.uri": regular,
                "punctuation.delimiter": regular,
                "string.escape": regular
            ]

        }

        public func font(forToken tokenName: TokenName) -> NSFont? {
            fonts[tokenName]
        }
    }
}
