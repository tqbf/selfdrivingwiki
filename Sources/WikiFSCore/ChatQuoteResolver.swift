import Foundation

/// Pure resolution of a `[[chat:Title#"quote"]]` quote anchor to a specific
/// message in a chat transcript — the chat analogue of how source quote anchors
/// (`[[source:Name#"quote"]]`) resolve against derived markdown.
///
/// `WikiLinkParser.splitFragment` already splits `[[chat:Title#"quote"]]` into
/// `base`/`fragment` generically (the fragment keeps the surrounding `"`), and
/// `WikiLinkMarkdown` already carries the fragment through the emitted
/// `wiki://chat?…#"quote"` URL. This type closes the remaining gap: given the
/// quote fragment and the transcript-visible events the chat web view renders,
/// find the message the quote points at.
///
/// Matching is whitespace-normalized + case-insensitive **first match** (mirrors
/// the source quote anchor's `wikiNormalized` substring search and
/// `ChatWebView`'s `window.find` highlight, so the two stay consistent: the
/// DOM highlight lands on the same message the resolver identifies).
public enum ChatQuoteResolver {

    /// Strip the surrounding `"` the parser keeps verbatim in the fragment.
    /// `splitFragment` returns `"the fix"` (with quotes) for `#"the fix"`; this
    /// yields the inner text to match (`the fix`). Inner quotes are preserved.
    public static func quoteText(_ fragment: String) -> String {
        var s = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        // Peel a single leading and trailing `"` (the anchor delimiter), not all
        // of them — a quote that itself contains `"` keeps its inner marks.
        if s.hasPrefix("\"") { s.removeFirst() }
        if s.hasSuffix("\"") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The searchable prose of one transcript event — the text a quote anchor
    /// can match. Mirrors what `ChatWebView.chatRowHTML` renders in each
    /// `.chat-row`: user/assistant/result prose (+ tool-call summaries). Empty
    /// for events that render no searchable row (deltas, messageStop, raw,
    /// empty result), so `messageIndex` naturally skips them.
    public static func searchableText(_ event: AgentEvent) -> String {
        switch event {
        case .userText(let text):
            return text
        case .assistantText(let text):
            return text
        case .result(_, let text):
            return text
        case .toolUse(let name, let summary):
            return summary.isEmpty ? name : "\(name) \(summary)"
        case .toolResult(_, let summary):
            return summary
        case .systemInit, .subagent, .assistantTextDelta, .messageStop, .raw:
            return ""
        case .turnFailed(let reason):
            return reason.description
        }
    }

    /// The index of the first event in `events` whose `searchableText` contains
    /// `fragment` (whitespace-normalized, case-insensitive substring). Returns
    /// `nil` when the fragment is empty or no event matches.
    ///
    /// `events` is the transcript-visible list the web view renders, so the
    /// returned index identifies "which message" — used to gate the DOM
    /// highlight (no point searching the document if no message contains the
    /// quote). `ChatWebView` performs the actual scroll + highlight via
    /// `window.find`, whose first-match semantics match this scan.
    public static func messageIndex(of fragment: String, in events: [AgentEvent]) -> Int? {
        let needle = quoteText(fragment).wikiNormalized.lowercased()
        guard !needle.isEmpty else { return nil }
        for (index, event) in events.enumerated() {
            let haystack = searchableText(event).wikiNormalized.lowercased()
            if haystack.contains(needle) { return index }
        }
        return nil
    }
}
