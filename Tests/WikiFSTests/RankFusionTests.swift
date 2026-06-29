import Foundation
import Testing
@testable import WikiFSCore

/// Reciprocal Rank Fusion unit tests. RRF is pure Swift (no model/vec), so it is
/// fully testable. Validates the core property: a doc ranking high in BOTH lists
/// outranks one ranking high in only a single list, plus dedupe + ordering.
struct RankFusionTests {

    private struct Doc { let id: PageID }
    private func d(_ raw: String) -> Doc { Doc(id: PageID(rawValue: raw)) }
    private func ids(_ docs: [Doc]) -> [String] { docs.map { $0.id.rawValue } }

    @Test func docInBothListsOutranksDocInOnlyOne() throws {
        // X is rank 1 in list A; Y is rank 2 in A but rank 1 in B.
        // Y appears in BOTH lists → its RRF score (1/62 + 1/61) beats X (1/61).
        let a = [d("X"), d("Y")]
        let b = [d("Y"), d("Z")]
        let fused = RankFusion.rrf([a, b], id: \.id)
        // Y (both) first, then X (rank-1 singleton) ahead of Z (rank-2 singleton).
        #expect(ids(fused) == ["Y", "X", "Z"])
    }

    @Test func dedupesByIdAcrossLists() throws {
        // Same doc ranks #1 in both lists — appears once, at the top.
        let a = [d("A"), d("B"), d("C")]
        let b = [d("A"), d("C"), d("D")]
        let fused = RankFusion.rrf([a, b], id: \.id)
        #expect(Set(ids(fused)) == Set(["A", "B", "C", "D"]))
        #expect(fused.first?.id.rawValue == "A")  // top of both lists
        #expect(fused.count == 4)                 // no duplicate A/C
    }

    @Test func singleListIsPreservedOrder() throws {
        let a = [d("a"), d("b"), d("c"), d("d")]
        let fused = RankFusion.rrf([a], id: \.id)
        #expect(ids(fused) == ["a", "b", "c", "d"])
    }

    @Test func disjointListsBothSurfaceAndRank() throws {
        // Two completely disjoint lists: the rank-1 of each ties on "best rank",
        // broken by first-seen order (list A's items seen first).
        let a = [d("a1"), d("a2")]
        let b = [d("b1"), d("b2")]
        let fused = RankFusion.rrf([a, b], id: \.id)
        #expect(Set(ids(fused)) == Set(["a1", "a2", "b1", "b2"]))
        // a1 and b1 both have best rank 1; a1 seen first → a1 before b1.
        #expect(fused.first?.id.rawValue == "a1")
    }

    @Test func emptyListsYieldEmpty() throws {
        #expect(RankFusion.rrf([], id: \Doc.id).isEmpty)
        #expect(RankFusion.rrf([[], []], id: \Doc.id).isEmpty)
    }
}
