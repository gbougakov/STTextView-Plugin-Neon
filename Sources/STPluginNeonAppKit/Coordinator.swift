import Cocoa
import STTextView

import Neon
import TreeSitterClient
import SwiftTreeSitter

// tree-sitter-xcframework
//import TreeSitter
import TreeSitterResource

@MainActor
public class Coordinator {
    /// A parallel `TreeSitterClient` for one sub-grammar injected into the host
    /// language (e.g. `markdown_inline` injected into `markdown`). It parses
    /// the whole document; we filter its tokens to the host's injection ranges
    /// before applying them.
    private struct InjectedClient {
        let name: String
        let client: TreeSitterClient
        let highlightsQuery: Query
    }

    private(set) var highlighter: Neon.Highlighter?
    private let language: TreeSitterLanguage
    private let tsLanguage: SwiftTreeSitter.Language
    private let tsClient: TreeSitterClient
    private let injectedClients: [InjectedClient]
    private let injectionsQuery: Query?
    private var prevViewportRange: NSTextRange?
    private var viewportUpdatePending = false

    init(textView: STTextView, theme: Theme, language: TreeSitterLanguage) {
        self.language = language
        tsLanguage = Language(language: language.parser)

        let transformer: Point.LocationTransformer = { codePointIndex in
            guard let location = textView.textContentManager.location(at: codePointIndex),
                  let position = textView.textContentManager.position(location)
            else {
                return .zero
            }
            return Point(row: position.row, column: position.column)
        }

        tsClient = try! TreeSitterClient(language: tsLanguage, transformer: transformer)

        // Spin up parallel clients for any sub-grammars the host language
        // injects (markdown → markdown_inline today). Each parses the whole
        // document independently; the token provider intersects their output
        // with the host's injection ranges so we don't style, e.g., the body
        // of a fenced code block as if it were inline markdown.
        var injected: [InjectedClient] = []
        var hostInjectionsQuery: Query? = nil
        if let injectionsURL = language.injectionsQueryURL,
           let parsedInjectionsQuery = try? tsLanguage.query(contentsOf: injectionsURL) {
            hostInjectionsQuery = parsedInjectionsQuery
            for (name, info) in language.injectedLanguages {
                let subLanguage = Language(language: info.parser)
                guard let subClient = try? TreeSitterClient(language: subLanguage, transformer: transformer),
                      let subHighlightsQuery = try? subLanguage.query(contentsOf: info.highlightsQueryURL)
                else {
                    continue
                }
                injected.append(InjectedClient(name: name, client: subClient, highlightsQuery: subHighlightsQuery))
            }
        }
        injectedClients = injected
        injectionsQuery = hostInjectionsQuery

        // All stored properties are now initialized; safe to install
        // invalidation handlers that capture `self`.
        tsClient.invalidationHandler = { [weak self] indexSet in
            self?.highlighter?.invalidate(.set(indexSet))
        }
        for injected in injectedClients {
            injected.client.invalidationHandler = { [weak self] indexSet in
                self?.highlighter?.invalidate(.set(indexSet))
            }
        }

        // set textview default font to theme default font
        textView.font = theme.font(forToken: "plain") ?? textView.font

        highlighter = Neon.Highlighter(textInterface: STTextViewSystemInterface(textView: textView) { neonToken in
            var attributes: [NSAttributedString.Key: Any] = [:]
            attributes[.font] = textView.font

            if let themeColor = theme.color(forToken: TokenName(neonToken.name)) {
                attributes[.foregroundColor] = themeColor

                if let themeFont = theme.font(forToken: TokenName(neonToken.name)) {
                    attributes[.font] = themeFont
                }
            } else if let themeDefaultColor = theme.color(forToken: "plain") {
                attributes[.foregroundColor] = themeDefaultColor

                if let themeFont = theme.font(forToken: TokenName(neonToken.name)) {
                    attributes[.font] = themeFont
                }
            }

            return !attributes.isEmpty ? attributes : nil
        }, tokenProvider: tokenProvider(textContentManager: textView.textContentManager))

        // initial parse of the whole content (all clients)
        let docRange = NSRange(textView.textContentManager.documentRange, in: textView.textContentManager)
        let length = textView.textContentManager.length
        let readFunction = Parser.readFunction(for: textView.textContentManager.attributedString(in: nil)?.string ?? "")

        tsClient.willChangeContent(in: docRange)
        tsClient.didChangeContent(in: docRange, delta: length, limit: length, readHandler: readFunction, completionHandler: {})
        for injected in injectedClients {
            injected.client.willChangeContent(in: docRange)
            injected.client.didChangeContent(in: docRange, delta: length, limit: length, readHandler: readFunction, completionHandler: {})
        }
    }

    private func tokenProvider(textContentManager: NSTextContentManager) -> Neon.TokenProvider? {

        guard let highlightsQuery = try? tsLanguage.query(contentsOf: language.highlightQueryURL!) else {
            return nil
        }

        let textProvider: SwiftTreeSitter.Predicate.TextProvider = { range, _ in
            guard range.isEmpty == false else { return nil }
            return textContentManager.attributedString(in: NSTextRange(range, provider: textContentManager))?.string
        }

        let blockProvider = tsClient.tokenProvider(with: highlightsQuery, textProvider: textProvider)

        guard !injectedClients.isEmpty, let injectionsQuery else {
            return blockProvider
        }

        let injectedClients = self.injectedClients
        let tsClient = self.tsClient

        return { range, completionHandler in
            blockProvider(range) { blockResult in
                guard case .success(let blockApp) = blockResult else {
                    completionHandler(blockResult)
                    return
                }

                // Locate which sub-ranges of `range` are flagged as
                // injections in the host grammar (e.g. `(inline)` nodes for
                // markdown). Injected-client tokens that don't sit inside one
                // of these are dropped — that's how we avoid styling
                // `*foo*` inside a fenced code block as emphasis.
                tsClient.executeInjectionsQuery(injectionsQuery, in: range, textProvider: textProvider) { injResult in
                    guard case .success(let injections) = injResult else {
                        completionHandler(.success(blockApp))
                        return
                    }

                    var rangesByName: [String: IndexSet] = [:]
                    for inj in injections {
                        guard let r = Range(inj.range) else { continue }
                        rangesByName[inj.name, default: IndexSet()].insert(integersIn: r)
                    }

                    var allTokens = blockApp.tokens
                    var pending = injectedClients.count

                    let finish: () -> Void = {
                        // TEMP DIAGNOSTIC — remove before merging
                        NSLog("NEON-DBG === composed tokens for range %@ ===", NSStringFromRange(range))
                        for t in allTokens {
                            NSLog("NEON-DBG   [%d..<%d) %@", t.range.location, t.range.location + t.range.length, t.name)
                        }
                        completionHandler(.success(TokenApplication(tokens: allTokens)))
                    }

                    if pending == 0 {
                        finish()
                        return
                    }

                    for injected in injectedClients {
                        guard let validRanges = rangesByName[injected.name], !validRanges.isEmpty else {
                            pending -= 1
                            if pending == 0 { finish() }
                            continue
                        }

                        let injectedProvider = injected.client.tokenProvider(with: injected.highlightsQuery, textProvider: textProvider)
                        injectedProvider(range) { injectedResult in
                            if case .success(let injectedApp) = injectedResult {
                                let filtered = injectedApp.tokens.filter { token in
                                    guard let r = Range(token.range) else { return false }
                                    return validRanges.contains(integersIn: r)
                                }
                                allTokens.append(contentsOf: filtered)
                            }
                            pending -= 1
                            if pending == 0 { finish() }
                        }
                    }
                }
            }
        }
    }

    /// Coalesce viewport-change re-highlights to at most one per main-runloop
    /// iteration. TextKit 2 fires `onDidLayoutViewport` many times during a
    /// single scroll gesture as it lays out fragments incrementally; without
    /// coalescing each tick re-runs `visibleContentDidChange()` against
    /// adjacent, mostly-overlapping ranges and drives frame time over budget
    /// on dense files (e.g. ~50 KB markdown at 120 Hz).
    func updateViewportRange(_ range: NSTextRange?) {
        guard range != prevViewportRange else { return }
        prevViewportRange = range

        guard !viewportUpdatePending else { return }
        viewportUpdatePending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportUpdatePending = false
            self.highlighter?.visibleContentDidChange()
        }
    }

    func willChangeContent(in range: NSRange) {
        tsClient.willChangeContent(in: range)
        for injected in injectedClients {
            injected.client.willChangeContent(in: range)
        }
    }

    func didChangeContent(_ textContentManager: NSTextContentManager, in range: NSRange, delta: Int, limit: Int) {
        /// TODO: Instead get the *whole* string over and over (can be expensive for large documents)
        /// implement maybe a reader function that read what needed only (is it possible?)
        if let str = textContentManager.attributedString(in: nil)?.string {
            let readFunction = Parser.readFunction(for: str)
            tsClient.didChangeContent(in: range, delta: delta, limit: limit, readHandler: readFunction, completionHandler: {})
            for injected in injectedClients {
                injected.client.didChangeContent(in: range, delta: delta, limit: limit, readHandler: readFunction, completionHandler: {})
            }
        }
    }
}
