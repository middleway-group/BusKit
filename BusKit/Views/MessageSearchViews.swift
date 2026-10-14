import SwiftUI

// MARK: - Find command plumbing

private struct FocusMessageSearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// Set by the Messages / Dead-letter tabs; nil elsewhere, which disables Edit → Find….
    var focusMessageSearch: (() -> Void)? {
        get { self[FocusMessageSearchKey.self] }
        set { self[FocusMessageSearchKey.self] = newValue }
    }
}

struct MessageSearchCommands: Commands {
    @FocusedValue(\.focusMessageSearch) private var focusSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusSearch == nil)
        }
    }
}

// MARK: - Toolbar search field

private struct MessageSearchModifier: ViewModifier {
    @Bindable var search: MessageSearchModel
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $search.query, placement: .toolbar, prompt: "Search Messages")
            .searchScopes($search.scope) {
                ForEach(MessageSearchScope.allCases) { scope in
                    Text(scope.rawValue)
                        .tag(scope)
                        .accessibilityLabel("Search in \(scope.rawValue)")
                }
            }
            .searchSuggestions {
                let text = search.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    Button { search.scope = .messageID } label: {
                        Label("Message ID contains “\(text)”", systemImage: "number")
                    }
                    Button { search.scope = .subject } label: {
                        Label("Subject contains “\(text)”", systemImage: "text.alignleft")
                    }
                }
            }
            .searchFocused($isFocused)
            .focusedSceneValue(\.focusMessageSearch, { isFocused = true })
    }
}

extension View {
    func messageSearch(_ search: MessageSearchModel) -> some View {
        modifier(MessageSearchModifier(search: search))
    }
}

// MARK: - Footer status

/// Left side of the table footer while a search is active: scope-aware status text,
/// progress and the "search all" / cancel actions.
struct MessageSearchStatusView: View {
    let search: MessageSearchModel
    let totalCount: Int64
    let canDeepSearch: Bool
    let startDeepSearch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if search.isDeepSearching {
                ProgressView(value: search.progress(total: totalCount))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .accessibilityLabel("Search progress")
            }
            Text(search.statusText(total: totalCount))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if search.isDeepSearching {
                Button("Cancel") { search.cancelDeepSearch() }
                    .controlSize(.small)
            } else if canDeepSearch && !search.deepFinished {
                Button("Search all \(totalCount.formatted()) messages…", action: startDeepSearch)
                    .controlSize(.small)
            }

            if let error = search.deepError {
                Text(error).foregroundStyle(.red).lineLimit(1)
            }
        }
    }
}

struct MessageSearchEmptyView: View {
    let search: MessageSearchModel
    let canDeepSearch: Bool
    let startDeepSearch: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Results for \u{201C}\(search.appliedQuery)\u{201D}", systemImage: "magnifyingglass")
        } description: {
            Text("Check the spelling or try a new search.")
        } actions: {
            if canDeepSearch && !search.deepFinished {
                Button("Search all messages", action: startDeepSearch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Highlighted cells

struct MessageIDCell: View {
    let message: MessageItem
    let search: MessageSearchModel

    var body: some View {
        Text(message.messageId.isEmpty
             ? AttributedString("—")
             : highlightedText(message.messageId, query: search.appliedQuery,
                               field: .messageID, scope: search.appliedScope))
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
    }
}

struct MessageSubjectCell: View {
    let message: MessageItem
    let search: MessageSearchModel

    var body: some View {
        Text(message.subject.isEmpty
             ? AttributedString("—")
             : highlightedText(message.subject, query: search.appliedQuery,
                               field: .subject, scope: search.appliedScope))
            .font(.system(.caption))
            .lineLimit(1)
    }
}
