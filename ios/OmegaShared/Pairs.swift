import Foundation

/// All-pairs rows (the IPOG method): each row picks one value index per factor, and every pair of
/// values of any two factors appears together in at least one row. Same sizes, same rows.
enum Pairs {
    static func rows(_ sizes: [Int]) -> [[Int]] {
        let sizes = sizes.map { max($0, 1) }
        guard let first = sizes.first else { return [[]] }
        guard sizes.count > 1 else { return (0..<first).map { [$0] } }
        // The first two factors: every pair.
        var rows: [[Int]] = []
        for a in 0..<sizes[0] {
            for b in 0..<sizes[1] { rows.append([a, b] + Array(repeating: -1, count: sizes.count - 2)) }
        }
        for k in 2..<sizes.count {
            // Pairs of factor k with each earlier factor still to cover, as (i, value of i, value of k).
            var open = Set<Triple>()
            for i in 0..<k {
                for vi in 0..<sizes[i] {
                    for vk in 0..<sizes[k] { open.insert(Triple(i: i, vi: vi, vk: vk)) }
                }
            }
            // Across: give each row the value of k that covers the most open pairs.
            for r in rows.indices {
                var best = 0, bestCount = -1
                for step in 0..<sizes[k] {
                    let vk = (r + step) % sizes[k]
                    let count = (0..<k).filter { rows[r][$0] >= 0 && open.contains(Triple(i: $0, vi: rows[r][$0], vk: vk)) }.count
                    if count > bestCount { (best, bestCount) = (vk, count) }
                }
                rows[r][k] = best
                for i in 0..<k where rows[r][i] >= 0 { open.remove(Triple(i: i, vi: rows[r][i], vk: best)) }
            }
            // Down: put what's left in rows with a free slot, or new rows.
            for t in open.sorted() {
                if let r = rows.firstIndex(where: { $0[k] == t.vk && $0[t.i] < 0 }) {
                    rows[r][t.i] = t.vi
                } else {
                    var row = Array(repeating: -1, count: sizes.count)
                    (row[t.i], row[k]) = (t.vi, t.vk)
                    rows.append(row)
                }
            }
        }
        // Free slots: any value covers no new pair, so spread them.
        for r in rows.indices {
            for f in rows[r].indices where rows[r][f] < 0 { rows[r][f] = r % sizes[f] }
        }
        return rows
    }

    private struct Triple: Hashable, Comparable {
        let i: Int, vi: Int, vk: Int
        static func < (a: Triple, b: Triple) -> Bool { (a.i, a.vi, a.vk) < (b.i, b.vi, b.vk) }
    }
}
