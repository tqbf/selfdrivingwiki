import Foundation

/// Mutation-testing schemata switch — see `make mutate` and AGENTS.md.
///
/// `swift-mutation-testing` rewrites each mutated function body into
/// `switch __swiftMutationTestingID { case "<id>": <mutated> default: <original> }`
/// then builds ONCE and re-runs the suite per mutant with
/// `__SWIFT_MUTATION_TESTING_ACTIVE=<id>` in the environment. The generated code
/// references this symbol *unqualified*, so it must be in scope in every module
/// that owns a mutated file.
///
/// The tool injects its own `__SMTSupport.swift` into the alphabetically-first
/// directory under `Sources/` — here `CSQLite`, a `.systemLibrary` target for
/// which SPM compiles no sources at all. The symbol is therefore invisible to
/// the modules actually being mutated, every schemata switch fails with
/// "cannot find '__swiftMutationTestingID' in scope", and all mutants come back
/// Unviable (#823, #860).
///
/// Declaring it here, `public`, in the leaf target that the rest of the package
/// imports, fixes that with no fork of the tool: `import WikiFSTypes` brings a
/// public top-level `let` into unqualified scope. The tool's own injected copy
/// lands in the inert `CSQLite` directory and never collides with this one.
///
/// In a normal build the environment variable is absent, the value is `""`, and
/// every schemata switch takes its `default:` (original) branch — so this is
/// inert outside a mutation run.
public let __swiftMutationTestingID: String =
    ProcessInfo.processInfo.environment["__SWIFT_MUTATION_TESTING_ACTIVE"] ?? ""
