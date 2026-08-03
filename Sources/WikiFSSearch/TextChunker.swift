import Foundation

/// Recursive character text splitter — a Swift port of LangChain's
/// `RecursiveCharacterTextSplitter` / Chonkie's `RecursiveChunker`.
///
/// Splits text using a separator hierarchy (`"\n\n"` → `"\n"` → `" "` → `""`),
/// recursively descending until each piece fits `chunkSize`, then greedily
/// merges pieces back into chunks of ~`chunkSize` with `overlap` carried from
/// the tail of one chunk to the head of the next. Tries to break on the
/// largest meaningful boundary first (paragraph, then line, then word) so
/// chunks stay coherent.
///
/// Why this exists: Apple's `NLEmbedding.vector(for:)` is slow on long input
/// (~5 s per 100k chars) and throws an **uncatchable C++ `std::bad_alloc`**
/// above ~250k chars, crashing the app. Chunking keeps every embedding input
/// small, fast, and crash-free.
///
/// Pure + deterministic: no I/O, no globals. Unit-testable in isolation.
public enum TextChunker {

    /// Split `text` into chunks of approximately `chunkSize` characters, each
    /// overlapping the previous by `overlap` characters.
    ///
    /// - Parameters:
    ///   - chunkSize: Target maximum character count per chunk.
    ///   - overlap: Characters carried from the end of one chunk to the start of
    ///     the next (kept < `chunkSize`).
    ///   - separators: Boundary hierarchy, coarsest first. The default suits
    ///     markdown/prose. `""` means "split on individual characters" — the
    ///     last-resort fallback for a single huge run with no whitespace.
    public static func chunk(
        _ text: String,
        chunkSize: Int = 4000,
        overlap: Int = 400,
        separators: [String] = ["\n\n", "\n", " ", ""]
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let size = max(1, chunkSize)
        let lap = min(max(0, overlap), size - 1)   // overlap must be < chunkSize
        // 1. Recursively break the text into atomic pieces no larger than `size`,
        //    preferring the coarsest separator that's actually present.
        var pieces: [String] = []
        split(text, separators: separators, chunkSize: size, into: &pieces)
        // 2. Greedily recombine pieces into ~`size` chunks with `lap` overlap.
        return merge(pieces, chunkSize: size, overlap: lap)
    }

    // MARK: - Split

    /// Recursively break `text` into pieces ≤ `chunkSize`, appending to `out`.
    private static func split(
        _ text: String,
        separators: [String],
        chunkSize: Int,
        into out: inout [String]
    ) {
        if text.count <= chunkSize {
            out.append(text)
            return
        }
        // Pick the first (coarsest) separator actually present; everything after
        // it becomes the hierarchy for the next recursion level. If none of the
        // separators is present, fall back to a hard character split.
        var chosenSep = separators.last ?? ""
        var nextSeparators: [String] = []
        for (idx, sep) in separators.enumerated() {
            if sep.isEmpty || text.contains(sep) {
                chosenSep = sep
                nextSeparators = Array(separators.dropFirst(idx + 1))
                break
            }
        }
        if chosenSep.isEmpty {
            out.append(contentsOf: characterRuns(text, size: chunkSize))
            return
        }
        for part in text.components(separatedBy: chosenSep) where !part.isEmpty {
            if part.count <= chunkSize {
                out.append(part)
            } else {
                split(part, separators: nextSeparators, chunkSize: chunkSize, into: &out)
            }
        }
    }

    /// Slice `s` into consecutive `size`-character runs (the no-separator
    /// fallback for a single giant token).
    private static func characterRuns(_ s: String, size: Int) -> [String] {
        var runs: [String] = []
        var lo = s.startIndex
        while lo < s.endIndex {
            let hi = s.index(lo, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            runs.append(String(s[lo..<hi]))
            lo = hi
        }
        return runs
    }

    // MARK: - Merge

    /// Greedily pack `pieces` into chunks ≤ `chunkSize`. When a chunk is full it
    /// is emitted and the next chunk begins with the last `overlap` characters
    /// of the emitted chunk, so consecutive chunks share a context window.
    private static func merge(_ pieces: [String], chunkSize: Int, overlap: Int) -> [String] {
        guard !pieces.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        var currentLen = 0
        for piece in pieces {
            // Cost of appending: a joining space (if not first) + the piece.
            let join = current.isEmpty ? 0 : 1
            if currentLen + join + piece.count > chunkSize, !current.isEmpty {
                chunks.append(current)
                let tail = String(current.suffix(overlap))
                current = tail
                currentLen = tail.count
            }
            if current.isEmpty {
                current = piece
                currentLen = piece.count
            } else {
                current += " " + piece
                currentLen += 1 + piece.count
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
