import SwiftUI
import AppKit

// MARK: - MessageBodyPanel

@available(macOS 15.0, *)
struct MessageBodyPanel: View {
    let message: MessageItem?

    @State private var copied       = false
    @State private var showFindBar  = false
    @State private var searchText   = ""
    @FocusState private var searchFocused: Bool

    // MARK: Cached state (updated via onChange, not recomputed on every render)

    /// Cached JSON highlight result for the current message body.
    @State private var cachedJsonResult: JSONHighlighter.Result? = nil
    /// Pre-built attributed string with syntax highlighting (no search marks).
    @State private var cachedBaseAttributed: NSAttributedString = NSAttributedString()
    /// Final attributed string shown in the text view (includes search highlights).
    @State private var displayAttributed: NSAttributedString = NSAttributedString()
    /// Number of matches for the current debounced search term.
    @State private var matchCount: Int = 0
    /// Debounced copy of searchText — expensive work only runs after typing pauses.
    @State private var debouncedSearchText: String = ""
    @State private var debounceTask: Task<Void, Never>? = nil

    // MARK: Derived (cheap, computed inline)

    private var rawBody: String { message?.body ?? "" }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────
            HStack(spacing: 6) {
                Text("Body").font(.caption).foregroundStyle(.secondary)

                if cachedJsonResult != nil {
                    Text("JSON")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.blue.opacity(0.12)).foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if !rawBody.isEmpty {
                    // Search toggle button
                    Button {
                        showFindBar.toggle()
                        if showFindBar { searchFocused = true }
                        else { searchText = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(showFindBar ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Find in body (⌘F)")

                    // Copy button
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cachedBaseAttributed.string, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy body to clipboard")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)

            Divider()

            // ── Find bar ─────────────────────────────────────────
            if showFindBar {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)

                        TextField("Search…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(.caption, design: .monospaced))
                            .focused($searchFocused)
                            .onKeyPress(.escape) {
                                searchText  = ""
                                showFindBar = false
                                return .handled
                            }

                        if !searchText.isEmpty {
                            Text(matchCount == 0
                                 ? "No matches"
                                 : "\(matchCount) match\(matchCount == 1 ? "" : "es")")
                                .font(.caption)
                                .foregroundStyle(matchCount == 0 ? .red : .secondary)
                                .monospacedDigit()
                        }

                        Spacer()

                        Button {
                            searchText  = ""
                            showFindBar = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Close find bar (Esc)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.bar)

                    Divider()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Content ──────────────────────────────────────────
            if !rawBody.isEmpty {
                BodyTextView(attributed: displayAttributed)
            } else {
                Text("Select a message to view its body.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
        }
        // CMD+F keyboard shortcut — works regardless of what has focus
        .background {
            Button("") {
                showFindBar = true
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        }
        // Reset find state when a different message is selected; rebuild cached attributed string.
        .onChange(of: message?.messageId) { _, _ in
            searchText          = ""
            debouncedSearchText = ""
            showFindBar         = false
            debounceTask?.cancel()
            rebuildBaseAttributed()
        }
        // Trigger on first appearance so cachedBaseAttributed is populated.
        .onAppear {
            rebuildBaseAttributed()
        }
        // Debounce search input: wait 150 ms after the last keystroke before applying highlights.
        .onChange(of: searchText) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
                applySearchHighlights()
            }
        }
    }

    // MARK: - Cache helpers

    /// Rebuilds the base attributed string (syntax highlighting only, no search marks).
    /// Call whenever the message body changes.
    private func rebuildBaseAttributed() {
        guard !rawBody.isEmpty else {
            cachedJsonResult      = nil
            cachedBaseAttributed  = NSAttributedString()
            displayAttributed     = NSAttributedString()
            matchCount            = 0
            return
        }
        let result = JSONHighlighter.highlight(rawBody)
        cachedJsonResult = result
        if let result {
            cachedBaseAttributed = JSONHighlighter.nsAttributed(result.pretty)
        } else {
            let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            cachedBaseAttributed = NSAttributedString(
                string: rawBody,
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        }
        applySearchHighlights()
    }

    /// Overlays search-match highlights onto `cachedBaseAttributed` and updates `matchCount`.
    /// Uses `debouncedSearchText` so it only runs after typing has paused.
    private func applySearchHighlights() {
        guard !debouncedSearchText.isEmpty else {
            displayAttributed = cachedBaseAttributed
            matchCount        = 0
            return
        }

        let base   = cachedBaseAttributed.mutableCopy() as! NSMutableAttributedString
        let str    = base.string
        let query  = debouncedSearchText
        var count  = 0
        var range  = str.startIndex..<str.endIndex

        while let r = str.range(of: query, options: .caseInsensitive, range: range) {
            base.addAttribute(.backgroundColor,
                              value: NSColor.systemYellow.withAlphaComponent(0.5),
                              range: NSRange(r, in: str))
            count += 1
            range  = r.upperBound..<str.endIndex
        }

        displayAttributed = base
        matchCount        = count
    }
}

// MARK: - BodyTextView (NSTextView wrapper — rendering only)

private struct BodyTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let textView = LineNumberTextView()
        textView.isEditable                       = false
        textView.isSelectable                     = true
        textView.backgroundColor                  = .clear
        textView.drawsBackground                  = false
        // Extra left inset reserves space for the line-number gutter.
        textView.textContainerInset               = NSSize(
            width: LineNumberTextView.gutterWidth + 12, height: 10)
        textView.autoresizingMask                 = [.width]
        textView.isVerticallyResizable            = true
        textView.isHorizontallyResizable          = false
        textView.textContainer?.widthTracksTextView = true

        let scroll                   = NSScrollView()
        scroll.documentView          = textView
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers    = true
        scroll.drawsBackground       = false
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let savedOffset = scrollView.documentVisibleRect.origin
        textView.textStorage?.setAttributedString(attributed)
        textView.needsDisplay = true
        DispatchQueue.main.async {
            scrollView.documentView?.scroll(savedOffset)
        }
    }
}

// MARK: - LineNumberTextView
//
// Draws the line-number gutter directly inside draw(_:) so that it scrolls
// naturally with the text and requires no ruler-view layout machinery.

private final class LineNumberTextView: NSTextView {
    static let gutterWidth: CGFloat = 44
    private let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        drawGutter(in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawGutter(in rect: NSRect) {
        guard let layoutManager else { return }

        // ── Background ──────────────────────────────────────────
        let isDark = effectiveAppearance.name == .darkAqua
                  || effectiveAppearance.name == .vibrantDark
        let bgColor = isDark
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        bgColor.setFill()
        NSRect(x: 0, y: rect.minY, width: Self.gutterWidth, height: rect.height).fill()

        // ── Right-edge separator ─────────────────────────────────
        NSColor.separatorColor.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: Self.gutterWidth - 0.5, y: rect.minY))
        sep.line(to: NSPoint(x: Self.gutterWidth - 0.5, y: rect.maxY))
        sep.lineWidth = 1
        sep.stroke()

        // ── Line number labels ───────────────────────────────────
        let attrs: [NSAttributedString.Key: Any] = [
            .font: gutterFont,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let insetY   = textContainerInset.height
        let nsString = string as NSString
        var charIdx  = 0
        var lineNum  = 1

        while charIdx <= nsString.length {
            let charRange  = nsString.lineRange(for: NSRange(location: charIdx, length: 0))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: charRange, actualCharacterRange: nil)

            if glyphRange.length > 0 {
                var effectiveRange = NSRange()
                let fragRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location, effectiveRange: &effectiveRange)

                let y = fragRect.minY + insetY
                if y > rect.maxY { break }
                if y + fragRect.height >= rect.minY {
                    let label = "\(lineNum)" as NSString
                    let size  = label.size(withAttributes: attrs)
                    let lx    = Self.gutterWidth - size.width - 8
                    let ly    = y + (fragRect.height - size.height) / 2
                    label.draw(at: NSPoint(x: lx, y: ly), withAttributes: attrs)
                }
            }

            let next = NSMaxRange(charRange)
            if next == charIdx || next > nsString.length { break }
            charIdx = next
            lineNum += 1
        }
    }
}
