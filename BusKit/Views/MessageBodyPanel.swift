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

    // MARK: Derived

    private var rawBody: String { message?.body ?? "" }

    private var prettyBody: String {
        jsonResult?.pretty ?? rawBody
    }

    private var jsonResult: JSONHighlighter.Result? {
        guard !rawBody.isEmpty else { return nil }
        return JSONHighlighter.highlight(rawBody)
    }

    private var matchCount: Int {
        guard !searchText.isEmpty else { return 0 }
        var count = 0
        var range = prettyBody.startIndex..<prettyBody.endIndex
        while let r = prettyBody.range(of: searchText, options: .caseInsensitive, range: range) {
            count += 1
            range = r.upperBound..<prettyBody.endIndex
        }
        return count
    }

    /// NSAttributedString with syntax highlighting + optional search highlights.
    private var displayAttributed: NSAttributedString {
        let base: NSMutableAttributedString
        if let result = jsonResult {
            base = JSONHighlighter.nsAttributed(result.pretty).mutableCopy()
                as! NSMutableAttributedString
        } else if !rawBody.isEmpty {
            let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            base = NSMutableAttributedString(string: rawBody,
                                             attributes: [.font: mono,
                                                          .foregroundColor: NSColor.labelColor])
        } else {
            return NSAttributedString()
        }

        // Layer search highlights on top
        guard !searchText.isEmpty else { return base }
        let str = base.string
        var range = str.startIndex..<str.endIndex
        while let r = str.range(of: searchText, options: .caseInsensitive, range: range) {
            base.addAttribute(.backgroundColor,
                              value: NSColor.systemYellow.withAlphaComponent(0.5),
                              range: NSRange(r, in: str))
            range = r.upperBound..<str.endIndex
        }
        return base
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────
            HStack(spacing: 6) {
                Text("Body").font(.caption).foregroundStyle(.secondary)

                if jsonResult != nil {
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
                        NSPasteboard.general.setString(prettyBody, forType: .string)
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
                    .font(.system(.body, design: .monospaced))
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
        // Reset find state when a different message is selected
        .onChange(of: message?.id) { _, _ in
            searchText  = ""
            showFindBar = false
        }
    }
}

// MARK: - BodyTextView (NSTextView wrapper — rendering only)

private struct BodyTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let textView                              = NSTextView()
        textView.isEditable                       = false
        textView.isSelectable                     = true
        textView.backgroundColor                  = .clear
        textView.drawsBackground                  = false
        textView.textContainerInset               = NSSize(width: 12, height: 10)
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
        // Preserve scroll position when only highlights change
        let savedOffset = scrollView.documentVisibleRect.origin
        textView.textStorage?.setAttributedString(attributed)
        DispatchQueue.main.async {
            scrollView.documentView?.scroll(savedOffset)
        }
    }
}
