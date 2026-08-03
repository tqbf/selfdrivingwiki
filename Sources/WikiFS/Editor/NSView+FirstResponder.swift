import AppKit

extension NSView {
    /// Pure predicate: would `firstResponder` make `view` the active target —
    /// i.e. is it `view` itself, or a descendant such as an inline field editor
    /// hosted by an `NSTableView`?
    ///
    /// `performKeyEquivalent(with:)` is dispatched across the window's entire
    /// view hierarchy for every key-down event — not just to the first
    /// responder — so view-scoped shortcuts must consult this before acting,
    /// otherwise they steal key equivalents from other first responders in the
    /// same window (e.g. Cmd+A in the omnibox, issue #154).
    ///
    /// Split out as a pure function so the gating decision can be tested
    /// without depending on window key/visibility state, which AppKit does not
    /// reliably commit in a headless test environment.
    static func isFirstResponder(
        _ firstResponder: NSResponder?,
        selfOrDescendantOf view: NSView
    ) -> Bool {
        guard let firstResponder else { return false }
        if firstResponder === view { return true }
        if let responderView = firstResponder as? NSView,
           responderView.isDescendant(of: view) {
            return true
        }
        return false
    }

    /// Convenience: true when this view (or a descendant) is the window's
    /// current first responder.
    func isSelfOrDescendantFirstResponder() -> Bool {
        Self.isFirstResponder(window?.firstResponder, selfOrDescendantOf: self)
    }
}
