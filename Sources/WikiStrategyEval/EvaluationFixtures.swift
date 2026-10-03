import Foundation

/// The three authored local fixtures. No remote acquisition: every byte the
/// agent sees originates here, so every assertion phrase is traceable to a
/// known source or is deliberately absent from all sources (unsupported-claim
/// controls).
public enum EvaluationFixtures {

    // MARK: - Scenario 1: character history across sources

    public static let characterHistory = EvaluationScenario(
        id: .characterHistoryAcrossSources,
        strategy: EvaluationStrategyFixture(
            name: "Story analysis (evaluation fixture)",
            instructions: """
            Track characters, their relationships, and the order in which the story \
            reveals information versus the order events happened. One page per \
            character, titled with the character's full name.

            - Retain every fact the sources state about a character; never drop \
            earlier facts when a later source arrives.
            - When a later source corrects an earlier interpretation, keep the \
            corrected interpretation as the current account. Keep the earlier \
            interpretation only as history, clearly marked as an earlier belief, \
            with the source that stated it.
            - Cite the source for every claim with a `[[source:…]]` link.
            - Do not invent facts no source states.
            """),
        batches: [
            [EvaluationSourceFixture(
                filename: "meridian-chapter-03.md",
                markdown: """
                # Meridian — Chapter 3

                The icebreaker *Meridian* cleared the shelf ice on the third day out.
                Mara Voss is the chief cartographer of the *Meridian*; she has held
                that post for nine years and signs every chart the bridge navigates by.

                At 0210 the beacon at Kelso Harbor went dark. When the housing was
                recovered, the crew found tool marks on the latch — the same gouge
                pattern Mara's ice-chisels leave. Third Mate Ferrin told the watch he
                believed Mara sabotaged the beacon to fake their position, and the
                watch log recorded his accusation. Mara refused to answer questions
                about the latch.
                """)],
            [EvaluationSourceFixture(
                filename: "meridian-chapter-07.md",
                markdown: """
                # Meridian — Chapter 7

                The inquiry found the beacon latch was forced with a deck-splice bar,
                not an ice-chisel. The logbook of the *Meridian* names Ilya Voss —
                Mara Voss's brother, hired onto the deck crew in chapter 5 — at the
                beacon house at 0140 that night. Ilya confessed he sabotaged the
                beacon and planted his sister's chisel marks to frame her, because
                Mara had reported his forged depth soundings to the master.

                Mara Voss remains the chief cartographer of the *Meridian*. The
                inquiry also established that at 0210 Mara shut the harbor relay,
                which is what warned the fleet off the reef — her action saved the
                convoy. Third Mate Ferrin withdrew his accusation.
                """)],
        ],
        checks: [
            .retainedFact(
                pageTitle: "Mara Voss",
                phrases: ["chief cartographer", "Meridian"]),
            .supersededInterpretation(
                pageTitle: "Mara Voss",
                correctedPhrases: ["Ilya"],
                supersededPhrases: ["sabotaged the beacon"],
                qualifiers: [
                    "previously", "believed", "earlier", "initially", "originally",
                    "superseded", "formerly", "mistakenly", "accused", "accusation",
                    "chapter 3", "chapter 5", "withdrew", "confessed", "suspicion",
                ]),
            .citationsPresent(
                pageTitle: "Mara Voss",
                sourceFragments: ["meridian-chapter-03", "meridian-chapter-07"]),
            .stablePageIdentity(pageTitle: "Mara Voss"),
            .historyDepth(pageTitle: "Mara Voss", minimumVersions: 2),
            .provenanceIncludes(
                pageTitle: "Mara Voss",
                sourceFragments: ["meridian-chapter-03", "meridian-chapter-07"]),
            // Allowed pages: the characters the fixture sources name and the
            // strategy says get their own page ("one page per character":
            // Mara Voss, Ferrin, Ilya Voss) plus the Index. Anything else
            // the run creates or edits is an unrelated edit.
            .noUnrelatedPageEdits(allowedTitleFragments: ["Mara Voss", "Ferrin", "Ilya", "Index"]),
            .unsupportedClaim(
                pageTitle: "Mara Voss",
                phrases: ["Kelso Pact", "pirate", "treason", "navigation officer"]),
        ],
        rubric: [
            RubricQuestion(
                question: "Does the page present the corrected account (Ilya sabotaged the beacon, Mara's relay shutdown warned the fleet) as the current truth?",
                lookFor: "The corrected events read as what happened; the chapter-3 accusation reads as an earlier belief, not as fact."),
            RubricQuestion(
                question: "Does the page separate revelation order from event chronology?",
                lookFor: "The reader can tell which facts chapter 3 established before chapter 7 corrected them."),
            RubricQuestion(
                question: "Does every claim carry a citation?",
                lookFor: "No paragraph of character facts lacks a [[source:…]] link."),
        ])

    // MARK: - Scenario 2: superseded repository decision

    public static let supersededDecision = EvaluationScenario(
        id: .supersededRepositoryDecision,
        strategy: EvaluationStrategyFixture(
            name: "Repository history (evaluation fixture)",
            instructions: """
            Track components, decisions, and their rationale. One page per major
            architectural decision, titled after the decision's subject.

            - Record each decision with the rationale its own document states, and
            mark clearly which rationale is stated by a document versus inferred.
            - When a later document supersedes an earlier decision, present the
            superseding decision as the current one. Keep the earlier decision as
            history with its original rationale and the document that stated it.
            - Never present a superseded rationale as the current reason.
            - Cite the source for every claim with a `[[source:…]]` link.
            - Do not invent decisions or rationale no source states.
            - Use the stable page title `Storage architecture` for this decision.
            """),
        batches: [
            [EvaluationSourceFixture(
                filename: "adr-014-storage-layout.md",
                markdown: """
                # ADR 014: One shared database for all wikis

                Status: accepted (superseded by ADR 021).

                ## Decision

                Self Driving Wiki stores every wiki in ONE shared SQLite database
                inside the app group container.

                ## Stated rationale

                The team chose the single shared database because it gives one
                backup target, and because cross-wiki queries join without leaving
                the database file. The migration plan needs only one schema ladder.

                ## Consequences noted at the time

                Writers for different wikis contend on one write lock. The team
                accepted that contention because deployments were single-user.
                """)],
            [EvaluationSourceFixture(
                filename: "adr-021-per-wiki-databases.md",
                markdown: """
                # ADR 021: One database per wiki

                Status: accepted. Supersedes ADR 014.

                ## Decision

                Self Driving Wiki stores each wiki in its OWN SQLite database file,
                named by the wiki's ULID inside the app group container.

                ## Stated rationale

                ADR 014's single shared database made concurrent writers from the
                queue daemon block each other, and one corrupted file risked every
                wiki at once. Per-wiki databases let each wiki vacuum and migrate
                independently. The registry (`wikis.json`) replaces cross-file joins.

                ## Migration

                ADR 014's schema ladder moves to a per-wiki migrator. The shared
                database is retired after migration completes.
                """)],
        ],
        checks: [
            .retainedFact(
                pageTitle: "Storage architecture",
                phrases: ["own SQLite database", "per-wiki"]),
            .supersededInterpretation(
                pageTitle: "Storage architecture",
                correctedPhrases: ["supersedes ADR 014", "ADR 021"],
                supersededPhrases: [
                    "one shared database for all wikis",
                    "ONE shared SQLite database",
                    "single shared database"],
                qualifiers: [
                    "previously", "superseded", "earlier", "originally", "at the time",
                    "ADR 014", "retired", "history", "formerly", "accepted",
                ]),
            .retainedFact(
                pageTitle: "Storage architecture",
                phrases: ["one backup target", "cross-wiki"]),
            .citationsPresent(
                pageTitle: "Storage architecture",
                sourceFragments: ["adr-014-storage-layout", "adr-021-per-wiki-databases"]),
            .stablePageIdentity(pageTitle: "Storage architecture"),
            .historyDepth(pageTitle: "Storage architecture", minimumVersions: 2),
            .provenanceIncludes(
                pageTitle: "Storage architecture",
                sourceFragments: ["adr-014-storage-layout", "adr-021-per-wiki-databases"]),
            .noUnrelatedPageEdits(allowedTitleFragments: ["Storage architecture", "Index"]),
            .unsupportedClaim(
                pageTitle: "Storage architecture",
                phrases: ["PostgreSQL", "sharding", "multi-region"]),
        ],
        rubric: [
            RubricQuestion(
                question: "Is the per-wiki decision presented as current and the shared-database decision as history?",
                lookFor: "The page leads with ADR 021's decision; ADR 014 appears as the superseded history with its own rationale."),
            RubricQuestion(
                question: "Are stated and inferred rationale kept distinguishable?",
                lookFor: "Rationale attributed to an ADR reads as stated; anything the page infers says so."),
        ])

    // MARK: - Scenario 3: same evidence, different documentation strategy

    /// Evidence used identically by both legs of the documentation-strategy
    /// scenario.
    public static let bookmarkSyncEvidence = EvaluationSourceFixture(
        filename: "bookmark-sync-job.md",
        markdown: """
        # bookmark sync job

        The `bookmark sync` job reconciles the browser's live bookmarks with the
        wiki's bookmark tree. It runs from the command line.

        ## Flags

        - `--dry-run`: print the planned changes and exit without writing.
        - `--prune`: also delete wiki bookmark nodes whose browser counterpart
          disappeared. Without `--prune`, vanished counterparts are kept.
        - `--config <path>`: read the mapping from this TOML file instead of the
          default `bookmarks.toml`.

        ## Exit codes

        - `0`: the tree is in sync, or `--dry-run` printed a plan with no changes.
        - `3`: unresolved anchor — a wiki page named in the mapping no longer
          exists. The job writes nothing in this case.

        ## Config file

        `bookmarks.toml` maps browser folder paths to wiki page titles, one
        `[folder]` table per mapping.
        """)

    public static let documentationStrategy = EvaluationScenario(
        id: .sameEvidenceDifferentDocumentationStrategy,
        strategy: EvaluationStrategyFixture(
            name: "Diataxis how-to guide (evaluation fixture)",
            instructions: """
            Write pages as HOW-TO GUIDES in the Diataxis sense: task-oriented,
            for a reader who wants to accomplish one concrete thing.

            - Open by naming the task and its goal.
            - Number the steps the reader performs, in the order they perform
              them; one action per step.
            - State prerequisites before the first step.
            - Show the exact command for each step in a fenced code block.
            - Close by naming the result the reader should observe, including the
              exit code to expect.
            - Do not write reference material: no flag tables, no exhaustive
              enumeration of every option. Cover only what this task needs.
            - Use the stable page title `Bookmark sync` for this page.
            """),
        batches: [
            [bookmarkSyncEvidence],
        ],
        secondLegStrategy: EvaluationStrategyFixture(
            name: "Diataxis reference (evaluation fixture)",
            instructions: """
            Write pages as REFERENCE MATERIAL in the Diataxis sense:
            information-oriented, for a reader who looks something up.

            - Organize by topic with descriptive headings (flags, exit codes,
              configuration), not by task steps.
            - Describe each flag, exit code, and config key separately and
              completely.
            - Use terse, declarative sentences; no imperative steps, no
              numbered sequences, no narrative.
            - Do not tell the reader what to do; state what each item is and
              what it does.
            - Use the stable page title `Bookmark sync` for this page.
            """),
        checks: [
            .strategyShape(
                pageTitle: "Bookmark sync",
                requiredPhrases: ["dry-run"],
                forbiddenPhrases: ["Step 1 — Reference", "## Exit codes are listed alphabetically"],
                firstLeg: true),
            .strategyShape(
                pageTitle: "Bookmark sync",
                requiredPhrases: ["--prune", "--config"],
                forbiddenPhrases: ["Step 1", "Step 2"],
                firstLeg: false),
            .citationsPresent(pageTitle: "Bookmark sync", sourceFragments: ["bookmark-sync-job"]),
            .historyDepth(pageTitle: "Bookmark sync", minimumVersions: 1),
            .differentOutputShape(pageTitle: "Bookmark sync"),
        ],
        rubric: [
            RubricQuestion(
                question: "Does the first leg read as a how-to guide and the second as reference?",
                lookFor: "Leg 1: named task, prerequisites, numbered steps, commands, expected result. Leg 2: topic headings, complete per-item descriptions, no steps."),
            RubricQuestion(
                question: "Did the strategy — not the evidence — cause the difference?",
                lookFor: "Both legs cite the same source; only organization and voice differ."),
        ])

    // MARK: - Catalog

    public static let all: [EvaluationScenario] = [
        characterHistory,
        supersededDecision,
        documentationStrategy,
    ]

    public static func scenario(id: EvaluationScenarioID) -> EvaluationScenario? {
        all.first { $0.id == id }
    }
}
