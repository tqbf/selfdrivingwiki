import Foundation
import WikiFSCore

/// An editor action that needs an explicit in-surface confirmation before it
/// replaces nonempty draft content: applying a starter template, resetting to
/// the Default strategy, or reloading a conflict winner. Confirmed actions
/// render through ``WikiStrategyInlineConfirmation``.
///
/// `confirmTitle` is deliberately distinct from every ARMING button's label
/// (the controls row's "Reset to Default", the conflict banner's "Reload
/// From Wiki"), so accessibility-label-based control finding is never
/// ambiguous when both are visible at once.
enum WikiStrategyEditorPendingAction: Identifiable, Equatable {
    /// Copy `template` over the current draft contents.
    case replaceWithTemplate(WikiStrategyTemplate)
    /// Clear the custom strategy and return the wiki to Default.
    case resetToDefault
    /// Discard the draft and adopt the committed conflict winner.
    case reloadFromWiki

    var id: String {
        switch self {
        case .replaceWithTemplate(let template): return "template-\(template.id.rawValue)"
        case .resetToDefault: return "reset"
        case .reloadFromWiki: return "reload"
        }
    }

    /// What the user is about to replace, in one short sentence.
    var message: String {
        switch self {
        case .replaceWithTemplate(let template):
            return "Apply the “\(template.name)” template? This replaces the name and the instructions in the draft."
        case .resetToDefault:
            return "Remove the custom strategy? Future runs use the default strategy. Existing pages stay unchanged."
        case .reloadFromWiki:
            return "Reload the saved strategy? Your unsaved draft is replaced with the saved version."
        }
    }

    /// The confirming button's title (distinct from every arming button).
    var confirmTitle: String {
        switch self {
        case .replaceWithTemplate: return "Replace Draft"
        case .resetToDefault: return "Reset Strategy"
        case .reloadFromWiki: return "Reload Draft"
        }
    }

    /// The cancel button's title — distinct from the editor's own Cancel so
    /// both can be visible and found by label.
    static let cancelTitle = "Keep Current Draft"
}
