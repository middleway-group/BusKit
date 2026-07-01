import SwiftUI
import AppKit

/// A multi-line SQL text editor with syntax highlighting.
///
/// Wraps `NSTextView` to render keywords, string literals, numeric literals,
/// and comparison operators with distinct colours. Height auto-expands between
/// `minHeight` and `maxHeight`; beyond `maxHeight` the view scrolls vertically.
@available(macOS 15.0, *)
struct SQLHighlightTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 96
    var maxHeight: CGFloat = 240
    @Binding var dynamicHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        context.coordinator.textView = textView
        textView.delegate = context.coordinator

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        if !text.isEmpty {
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
        }

        DispatchQueue.main.async { context.coordinator.updateHeight(textView) }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        guard textView.string != text else { return }

        let savedRanges = textView.selectedRanges
        textView.string = text
        context.coordinator.applyHighlighting(to: textView)
        textView.selectedRanges = savedRanges

        DispatchQueue.main.async { context.coordinator.updateHeight(textView) }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLHighlightTextEditor
        weak var textView: NSTextView?

        init(_ parent: SQLHighlightTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            applyHighlighting(to: tv)
            updateHeight(tv)
        }

        func updateHeight(_ textView: NSTextView) {
            guard let lm = textView.layoutManager,
                  let tc = textView.textContainer else { return }
            lm.ensureLayout(for: tc)
            let contentHeight = lm.usedRect(for: tc).height
                              + textView.textContainerInset.height * 2
            let clamped = max(parent.minHeight, min(parent.maxHeight, ceil(contentHeight)))
            if abs(clamped - parent.dynamicHeight) > 0.5 {
                parent.dynamicHeight = clamped
            }
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string
            guard !source.isEmpty else { return }
            let fullRange = NSRange(source.startIndex..., in: source)

            storage.beginEditing()

            // Base: monospaced label colour
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            // 1. String literals:  'value'
            highlight("'[^']*'", in: source, storage: storage, color: .systemRed)

            // 2. Numeric literals: 123  or  1.5
            highlight("\\b\\d+(\\.\\d+)?\\b", in: source, storage: storage, color: .systemOrange)

            // 3. Comparison operators: =  <>  !=  >=  <=  >  <
            highlight("(<>|!=|>=|<=|[><](?!=)|(?<![<>!])=(?!=))",
                      in: source, storage: storage, color: .systemPurple)

            // 4. SQL keywords (applied last so they override other rules on
            //    ambiguous tokens like TRUE/FALSE which could match as identifiers)
            let kwPattern = "\\b(AND|OR|NOT|IN|LIKE|IS|NULL|TRUE|FALSE|BETWEEN|EXISTS|ANY|ALL)\\b"
            if let regex = try? NSRegularExpression(pattern: kwPattern, options: .caseInsensitive) {
                regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                    guard let r = match?.range else { return }
                    storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: r)
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                        range: r
                    )
                }
            }

            storage.endEditing()
        }

        private func highlight(_ pattern: String,
                                in text: String,
                                storage: NSTextStorage,
                                color: NSColor) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                if let r = match?.range {
                    storage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }
    }
}
