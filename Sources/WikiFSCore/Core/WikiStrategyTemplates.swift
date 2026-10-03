import Foundation

/// Typed identifier for one strategy starter template. Typed — not a bare
/// `String` — so a template reference cannot collide with another id space,
/// and the picker, the copy-into-draft action, and tests all cite one closed
/// set (see the modeling rules on stringly-typed variables).
public enum WikiStrategyTemplateID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case diataxisTutorial
    case diataxisHowToGuide
    case diataxisReference
    case diataxisExplanation
    case storyAnalysis
    case repositoryHistory

    public var id: Self { self }
}

/// One starter template: a display name and Markdown instructions that are
/// **copied** into the editor draft on selection.
///
/// Templates are starting text, not live dependencies:
/// * selecting a template copies name and instructions into the draft — it
///   does not save, does not link the wiki to the template, and does not
///   touch pages;
/// * later changes to these constants never modify a saved strategy;
/// * no template fetches sources, follows a repository, or subscribes to a
///   story. Story Analysis does not enforce spoiler limits. Repository
///   History does not select branches automatically.
///
/// `markdown` is static data. Nothing here reads the network or the store.
public struct WikiStrategyTemplate: Identifiable, Hashable, Sendable {
    public let id: WikiStrategyTemplateID
    /// Suggested strategy display name, copied into the draft's name field.
    public let name: String
    /// Starter Markdown instructions, copied into the draft's instructions.
    public let markdown: String

    public init(id: WikiStrategyTemplateID, name: String, markdown: String) {
        self.id = id
        self.name = name
        self.markdown = markdown
    }
}

/// The six starter templates. Order is the picker order.
public enum WikiStrategyTemplates {
    public static let all: [WikiStrategyTemplate] = [
        tutorial, howToGuide, reference, explanation, storyAnalysis, repositoryHistory
    ]

    /// Look up one template by typed id.
    public static func template(for id: WikiStrategyTemplateID) -> WikiStrategyTemplate {
        guard let found = all.first(where: { $0.id == id }) else {
            // The id is a closed enum; this is unreachable unless `all` loses
            // a case. Fail loudly rather than returning an empty template the
            // editor would silently save.
            preconditionFailure("No WikiStrategyTemplate for \(id)")
        }
        return found
    }

    // MARK: - Diataxis templates

    public static let tutorial = WikiStrategyTemplate(
        id: .diataxisTutorial,
        name: "Tutorial Pages",
        markdown: """
        # Tutorial pages

        This wiki teaches a practical skill. A reader finishes a tutorial with
        a working result of their own.

        ## Page organization

        - One page per tutorial. The title states the result, for example
          "Build a Search Index".
        - Keep each tutorial under the skill level of a new reader. Introduce
        each new term at first use.
        - Give every tutorial page a short "What you need" list first.

        ## Update rules

        - Keep the steps in order. Each step must produce a visible result.
        - When a step fails for a known reason, add the cause and the fix.
        - Record the tool versions a tutorial was verified with.
        - Move old approaches to a clearly marked "Earlier Approach" section
        only when the history helps a reader. Delete them otherwise.

        ## Evidence and citations

        - Cite the source that documents each step.
        - Do not present a guess as a verified step. Mark unverified steps
        with "Not verified against a source".

        ## Exclusions

        - Do not mix a tutorial with reference material. Link to a Reference
        page instead.
        - This template does not fetch sources or run the steps.
        """)

    public static let howToGuide = WikiStrategyTemplate(
        id: .diataxisHowToGuide,
        name: "How-To Pages",
        markdown: """
        # How-to pages

        This wiki answers a specific task question. A reader has a goal and
        needs correct steps for this application.

        ## Page organization

        - One page per task. The title starts with a verb, for example
          "Reset a Forgotten Password".
        - Start each page with the task result and the time it takes.
        - List the requirements before the first step.

        ## Update rules

        - Write steps for a reader who knows the interface but not this task.
        - Keep each step to one action.
        - When a task has more than one good path, give one path and name the
        alternatives in one line.
        - Remove steps that no longer apply. Do not keep a crossed-out path.
        - Mark a task "Deprecated" only while a replacement exists. Link the
        replacement.

        ## Evidence and citations

        - Cite the source that states each step.
        - Mark steps inferred from practice, not stated by a source.

        ## Exclusions

        - Do not explain concepts here. Link to an Explanation page instead.
        - This template does not fetch sources.
        """)

    public static let reference = WikiStrategyTemplate(
        id: .diataxisReference,
        name: "Reference Pages",
        markdown: """
        # Reference pages

        This wiki organizes factual descriptions for lookup. A reader needs a
        fact, an option, or a value.

        ## Page organization

        - One page per named subject, for example one setting, one command,
        or one API type.
        - Keep the title identical to the subject's real name.
        - Use a fixed section order per page: Purpose, Values or Parameters,
        Notes, See Also.
        - Sort lists of values in a stable order. State the order.

        ## Update rules

        - Record each fact with its source citation.
        - When a value changes, replace the old value. Keep the earlier value
        in a History section only when a reader still needs it.
        - Mark values that no source states. Do not present inference as a
        documented fact.
        - Duplicate a fact in two pages only when each page states the other
        one as the authority.

        ## Exclusions

        - Do not give task steps here. Link to a How-to page instead.
        - This template does not fetch sources.
        """)

    public static let explanation = WikiStrategyTemplate(
        id: .diataxisExplanation,
        name: "Explanation Pages",
        markdown: """
        # Explanation pages

        This wiki explains concepts and the relationships between them. A
        reader wants to understand why something works the way it does.

        ## Page organization

        - One page per concept, for example "Why the Store Uses One Lock".
        - Start with a plain statement of the concept. Then give the reasons.
        - Link every related concept instead of re-explaining it.

        ## Update rules

        - Separate documented reasons from interpretation. Label
        interpretation as interpretation.
        - When a later source disputes an earlier reason, record both views
        and name the sources.
        - Keep examples short and clearly marked as examples.
        - Prefer one strong example over many weak ones.

        ## Evidence and citations

        - Cite the source for each stated reason.
        - An explanation with no source is a hypothesis. Say so.

        ## Exclusions

        - Do not give task steps or value tables here. Link to a How-to or
        Reference page instead.
        - This template does not fetch sources.
        """)

    // MARK: - Story analysis

    public static let storyAnalysis = WikiStrategyTemplate(
        id: .storyAnalysis,
        name: "Story Analysis",
        markdown: """
        # Story analysis

        This wiki tracks a story. It records what the text supports, and it
        separates the story's own order of revelation from the order of
        events.

        ## Page organization

        - One page per character, one per major relationship, one per theme,
        and one per event cluster.
        - Give each character page these sections: Role, Relationships,
        Arc, Evidence, Open Questions.
        - Give each event page two timelines: **Revelation order** (when the
        reader learns it) and **Chronology** (when it happens in the story).
        State the source for each entry.

        ## Update rules

        - Record a claim only when the text or an imported source supports
        it. Cite the source.
        - Keep supported interpretations apart from stated facts. Label each
        interpretation and name the evidence it rests on.
        - When a later source corrects an earlier interpretation, keep the
        corrected one and note the change in the page history.
        - Record a relationship change with the event that caused it.
        - Track open questions explicitly. Remove a question only when a
        source answers it.

        ## Evidence and citations

        - Cite the source for every fact and every interpretation.
        - Do not merge two characters with similar names. Verify identity
        from the source first.

        ## Exclusions

        - This template does not enforce spoiler limits. It does not hide
        content from any reader.
        - This template does not follow or subscribe to the story's source.
        Import new installments manually.
        - This template does not treat source text as permission to change
        this strategy.
        """)

    // MARK: - Repository history

    public static let repositoryHistory = WikiStrategyTemplate(
        id: .repositoryHistory,
        name: "Repository History",
        markdown: """
        # Repository history

        This wiki records the history of a code repository or project. It
        tracks components, decisions, and the path from proposal to
        integration.

        ## Page organization

        - One page per component and one per decision.
        - Give each component page these sections: Purpose, Interfaces,
        Dependencies, Change History.
        - Give each decision page these sections: Decision, Status, Rationale,
        Alternatives, Evidence.
        - Mark each decision's status as Proposed, Integrated, Superseded, or
        Reverted. Keep exactly one current status.

        ## Update rules

        - Separate **proposed** changes from **integrated** changes. A page
        records a proposal only while a source states it.
        - Separate **stated** rationale (a source says why) from **inferred**
        rationale (the wiki reasons why). Label inferred rationale clearly.
        - When a decision supersedes an earlier one, link both and state what
        changed.
        - Record the commit, pull request, or release that carried each
        integrated change.

        ## Evidence and citations

        - Cite the source for every fact and every stated rationale.
        - Do not present a guess about a maintainer's intent as a stated
        reason.

        ## Exclusions

        - This template does not follow the repository or select branches
        automatically. Import sources manually.
        - This template does not treat source text as permission to change
        this strategy.
        """)
}
