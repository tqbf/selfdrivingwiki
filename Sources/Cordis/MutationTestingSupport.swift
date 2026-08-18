import Foundation

/// Mutation-testing schemata selector for the standalone Cordis module.
///
/// `swift-mutation-testing` injects unqualified references to this symbol into
/// mutated functions. Cordis has no product-module dependencies, so it needs
/// a local declaration. Normal builds use the empty value and original code.
public let __swiftMutationTestingID: String =
    ProcessInfo.processInfo.environment["__SWIFT_MUTATION_TESTING_ACTIVE"] ?? ""
