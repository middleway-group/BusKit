import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Scope & pure filtering

enum MessageSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case messageID = "Message ID"
    case subject = "Subject"

    var id: String { rawValue }
}

/// Returns the messages matching `query` (case-insensitive, contains) within `scope`.
/// An empty / whitespace-only query matches everything.
nonisolated func filter(messages: [MessageItem], query: String, scope: MessageSearchScope) -> [MessageItem] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return messages }
    return messages.filter { matches($0, needle: needle, scope: scope) }
}

nonisolated func matches(_ message: MessageItem, needle: String, scope: MessageSearchScope) -> Bool {
    switch scope {
    case .all:       return fieldMatches(message.messageId, needle) || fieldMatches(message.subject, needle)
    case .messageID: return fieldMatches(message.messageId, needle)
    case .subject:   return fieldMatches(message.subject, needle)
    }
}

private nonisolated func fieldMatches(_ field: String, _ needle: String) -> Bool {
    field.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

/// Text with every occurrence of `query` highlighted, for table cells.
/// Highlighting is skipped when the field is not part of the active scope.
func highlightedText(_ text: String, query: String, field: MessageSearchScope, scope: MessageSearchScope) -> AttributedString {
    var attributed = AttributedString(text)
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty, scope == .all || scope == field else { return attributed }
    var searchStart = text.startIndex
    while let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: searchStart..<text.endIndex),
          let lower = AttributedString.Index(range.lowerBound, within: attributed),
          let upper = AttributedString.Index(range.upperBound, within: attributed) {
        attributed[lower..<upper].backgroundColor = Color(nsColor: .findHighlightColor)
        attributed[lower..<upper].foregroundColor = Color(nsColor: .textColor)
        searchStart = range.upperBound
    }
    return attributed
}

// MARK: - Search state

/// Search state for a Messages / Dead-letter tab. The loaded message array stays
/// owned by the tab; this model only keeps the match results derived from it.
@MainActor
@Observable
final class MessageSearchModel {
    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    var scope: MessageSearchScope = .all { didSet { if scope != oldValue { queryChanged() } } }

    /// Query/scope the current results were computed for (lags `query` by the debounce).
    private(set) var appliedQuery = ""
    private(set) var appliedScope: MessageSearchScope = .all

    private(set) var loadedMatches: [MessageItem] = []
    private(set) var deepMatches: [MessageItem] = []
    private(set) var isDeepSearching = false
    private(set) var deepScanned = 0
    private(set) var deepFinished = false
    private(set) var deepError: String?

    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var deepTask: Task<Void, Never>?
    @ObservationIgnored private var latestLoaded: [MessageItem] = []

    var isFiltering: Bool {
        !appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var results: [MessageItem] { loadedMatches + deepMatches }
    var matchCount: Int { loadedMatches.count + deepMatches.count }
    var loadedCount: Int { latestLoaded.count }

    /// Fraction of `total` already scanned (loaded + deep-scanned), 0...1.
    func progress(total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(latestLoaded.count + deepScanned) / Double(total))
    }

    /// Re-derives the loaded matches. Call whenever the loaded messages change.
    func loadedMessagesChanged(_ loaded: [MessageItem]) {
        latestLoaded = loaded
        let seen = Set(loaded.map(\.sequenceNumber))
        deepMatches.removeAll { seen.contains($0.sequenceNumber) }
        refilter(debounce: false)
    }

    /// Called when the underlying entity changes or messages are reloaded from scratch.
    func reset(clearQuery: Bool) {
        cancelDeepSearch()
        resetDeepState()
        if clearQuery {
            filterTask?.cancel()
            query = ""
            appliedQuery = ""
            loadedMatches = []
        }
    }

    func clear() { reset(clearQuery: true) }

    func discard(sequenceNumber: Int64) {
        deepMatches.removeAll { $0.sequenceNumber == sequenceNumber }
    }

    private func queryChanged() {
        cancelDeepSearch()
        resetDeepState()
        refilter(debounce: true)
    }

    private func resetDeepState() {
        deepMatches = []
        deepScanned = 0
        deepFinished = false
        deepError = nil
    }

    private func refilter(debounce: Bool) {
        filterTask?.cancel()
        let query = query, scope = scope, loaded = latestLoaded
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appliedQuery = ""
            appliedScope = scope
            loadedMatches = []
            return
        }
        filterTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            let found = await Task.detached(priority: .userInitiated) {
                filter(messages: loaded, query: query, scope: scope)
            }.value
            if Task.isCancelled { return }
            self?.appliedQuery = query
            self?.appliedScope = scope
            self?.loadedMatches = found
        }
    }

    // MARK: Deep search

    func startDeepSearch(batches: AsyncThrowingStream<[MessageItem], Error>) {
        guard isFiltering, !isDeepSearching else { return }
        resetDeepState()
        isDeepSearching = true
        let query = appliedQuery, scope = appliedScope
        var seen = Set(latestLoaded.map(\.sequenceNumber))
        deepTask = Task { [weak self] in
            do {
                for try await batch in batches {
                    if Task.isCancelled { break }
                    // Guard against the service re-sending messages already loaded or scanned.
                    let fresh = batch.filter { seen.insert($0.sequenceNumber).inserted }
                    if fresh.isEmpty { break }
                    let found = await Task.detached(priority: .userInitiated) {
                        filter(messages: fresh, query: query, scope: scope)
                    }.value
                    if Task.isCancelled { break }
                    guard let self else { return }
                    self.deepScanned += fresh.count
                    self.deepMatches.append(contentsOf: found)
                }
                if !Task.isCancelled { self?.deepFinished = true }
            } catch {
                if !Task.isCancelled { self?.deepError = error.localizedDescription }
            }
            self?.isDeepSearching = false
        }
    }

    func cancelDeepSearch() {
        deepTask?.cancel()
        deepTask = nil
        isDeepSearching = false
    }

    // MARK: Footer text

    func statusText(total: Int64) -> String {
        let matchWord = matchCount == 1 ? "match" : "matches"
        if isDeepSearching {
            return "Searching… \((latestLoaded.count + deepScanned).formatted()) of \(total.formatted()) scanned · \(matchCount.formatted()) \(matchWord)"
        }
        if deepFinished {
            return "\(matchCount.formatted()) \(matchWord) in all \((latestLoaded.count + deepScanned).formatted()) messages searched"
        }
        if deepScanned > 0 {
            return "\(matchCount.formatted()) \(matchWord) in \((latestLoaded.count + deepScanned).formatted()) of \(total.formatted()) messages searched (cancelled)"
        }
        let loaded = latestLoaded.count
        return "\(matchCount.formatted()) \(matchWord) in \(loaded.formatted()) loaded message\(loaded == 1 ? "" : "s")"
    }
}
