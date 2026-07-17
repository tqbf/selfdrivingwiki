import Foundation

/// Reciprocal Rank Fusion (RRF) — combines multiple ranked result lists by rank
/// position rather than raw, incomparable scores (BM25 relevance vs cosine
/// distance). For document `d`: `score(d) = Σ 1/(k + rank_i(d))`, so a document
/// ranking high in SEVERAL lists outscores one ranking high in only a single
/// list. The standard constant is `k = 60` (the original TREC paper / Elasticsearch
/// default). Pure Swift over arrays — fully unit-testable, no model/vec needed.
public enum RankFusion {

    /// Fuse `lists` (each already ranked best-first) into one ranked list.
    /// Dedupes by `id`; ties break by best single-list rank, then by first-seen
    /// order. Returns one representative object per id (identical across lists for
    /// a given id). Truncate the result with `.prefix(limit)` at the call site.
    public static func rrf<T>(
        _ lists: [[T]],
        id keyPath: KeyPath<T, PageID>,
        k: Int = 60
    ) -> [T] {
        var score: [PageID: Double] = [:]
        var bestRank: [PageID: Int] = [:]
        var repr: [PageID: T] = [:]
        var firstSeen: [PageID: Int] = [:]
        var order = 0
        for list in lists {
            for (index, item) in list.enumerated() {
                let pid = item[keyPath: keyPath]
                let rank = index + 1
                score[pid, default: 0] += 1.0 / Double(k + rank)
                if bestRank[pid].map({ rank < $0 }) ?? true { bestRank[pid] = rank }
                if repr[pid] == nil { repr[pid] = item }
                if firstSeen[pid] == nil { firstSeen[pid] = order; order += 1 }
            }
        }
        return score.keys.sorted { a, b in
            let sa = score[a]!, sb = score[b]!
            if sa != sb { return sa > sb }
            let ra = bestRank[a]!, rb = bestRank[b]!
            if ra != rb { return ra < rb }
            return firstSeen[a]! < firstSeen[b]!
        }.map { repr[$0]! }
    }
}
