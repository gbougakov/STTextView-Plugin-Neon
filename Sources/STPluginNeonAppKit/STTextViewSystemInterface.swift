import Cocoa
import STTextView
import Neon

class STTextViewSystemInterface: TextSystemInterface {

    typealias AttributeProvider = (Neon.Token) -> [NSAttributedString.Key: Any]?

    private let textView: STTextView
    private let attributeProvider: AttributeProvider

    init(textView: STTextView, attributeProvider: @escaping AttributeProvider) {
        self.textView = textView
        self.attributeProvider = attributeProvider
    }

    func clearStyle(in range: NSRange) {
        guard let textRange = NSTextRange(range, in: textView.textContentManager) else {
            assertionFailure()
            return
        }

        textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
        textView.addAttributes([.font: textView.font, .foregroundColor: textView.textColor], range: range)
    }

    func applyStyle(to token: Neon.Token) {
        guard var attrs = attributeProvider(token),
              NSTextRange(token.range, in: textView.textContentManager) != nil
        else {
            return
        }

        // Preserve the nil-foreground-color guard from the previous per-key loop:
        // drop foregroundColor if the provider supplied a non-NSColor value.
        if let fg = attrs[.foregroundColor], !(fg is NSColor) {
            attrs.removeValue(forKey: .foregroundColor)
        }

        guard !attrs.isEmpty else { return }
        textView.addAttributes(attrs, range: token.range)
    }

    var length: Int {
        textView.textContentManager.length
    }

    var visibleRange: NSRange {
        guard let viewportRange = textView.textLayoutManager.textViewportLayoutController.viewportRange else {
            return .zero
        }

        return NSRange(viewportRange, provider: textView.textContentManager)
    }
}
