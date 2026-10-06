import Foundation
import Testing
@testable import WikiFSCore

/// `WikiChangeWakeRouting` tests — the pure "which wikis does a payload-free
/// wake refresh?" decision behind issue #1374.
///
/// These live in the portable `WikiFSCoreTests` target (not the opt-in app
/// target) so the regression pin runs in the default `make test` graph.
struct WikiChangeWakeRoutingTests {
    private let wikiA = WikiID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA")
    private let wikiB = WikiID(rawValue: "01BBBBBBBBBBBBBBBBBBBBBBBB")

    /// The regression pin for #1374: a wake resolves against the wiki set it is
    /// GIVEN, so a wiki the caller never saw at launch is still refreshed.
    ///
    /// On the old per-wiki scheme this could not hold: the receiver matched the
    /// posted name against a launch-time subscription set and silently dropped
    /// any name outside it, so a wiki created while the app ran was inaudible.
    @Test func wakeResolvesForWikiAbsentFromLaunchTimeSet() {
        let resolved = WikiChangeWakeRouting.wikiIDs(
            forNotificationName: WikiChangeNotification.baseName,
            knownWikiIDs: [wikiA, wikiB])

        #expect(resolved == [wikiA, wikiB])
    }

    /// A single-wiki registry (the launch-time set the old scheme would have
    /// subscribed to) resolves to that wiki, and the result grows with the set
    /// with no separate refresh step.
    @Test func wakeFollowsTheCurrentRegistryNotTheLaunchTimeSet() {
        let launchTimeSet: [WikiID] = [wikiA]
        #expect(
            WikiChangeWakeRouting.wikiIDs(
                forNotificationName: WikiChangeNotification.baseName,
                knownWikiIDs: launchTimeSet) == [wikiA])

        // Wiki B was created after launch; the next wake covers it with no
        // explicit refresh call anywhere.
        let afterCreation: [WikiID] = [wikiA, wikiB]
        #expect(
            WikiChangeWakeRouting.wikiIDs(
                forNotificationName: WikiChangeNotification.baseName,
                knownWikiIDs: afterCreation) == [wikiA, wikiB])
    }

    /// The wake carries no wiki id, so it cannot address a single wiki — this
    /// pins the deliberate fan-out choice. A wake is never resolved to a subset.
    @Test func wakeFansOutToEveryKnownWiki() {
        let many = (0..<5).map { WikiID(rawValue: "01WIKI\($0)") }
        let resolved = WikiChangeWakeRouting.wikiIDs(
            forNotificationName: WikiChangeNotification.baseName,
            knownWikiIDs: many)

        #expect(resolved?.count == many.count)
    }

    /// An empty registry resolves to an empty refresh set — not `nil`, which
    /// would mean "this is not a wiki-change wake at all".
    @Test func wakeWithEmptyRegistryResolvesToEmptySet() {
        #expect(
            WikiChangeWakeRouting.wikiIDs(
                forNotificationName: WikiChangeNotification.baseName,
                knownWikiIDs: []) == [])
    }

    /// A name from another namespace is not a wiki-change wake, so the bridge
    /// leaves it to the renderer-machine route. `nil` is what distinguishes
    /// "not ours" from "ours, with nothing to refresh".
    @Test func foreignNotificationNameIsNotAWikiWake() {
        #expect(
            WikiChangeWakeRouting.wikiIDs(
                forNotificationName: RendererChangeNotification.machineBaseName,
                knownWikiIDs: [wikiA]) == nil)
        #expect(
            WikiChangeWakeRouting.wikiIDs(
                forNotificationName: "org.sockpuppet.wiki.changed.\(wikiA.rawValue)",
                knownWikiIDs: [wikiA]) == nil)
    }
}
