// Sources/BlackSwanEditCore/FenwickTree.swift
//
// A Fenwick (Binary-Indexed) Tree over UInt64 values.
// Used for O(log n) prefix-sum queries — specifically to map
// piece-index → cumulative byte offset and cumulative newline count.

import Foundation

public struct FenwickTree<T: BinaryInteger> {
    private var tree: [T]
    public private(set) var count: Int

    public init(count: Int) {
        self.count = count
        tree = Array(repeating: 0, count: count + 1)
    }

    /// Update position i (1-indexed) by adding delta.
    public mutating func update(at i: Int, delta: T) {
        var i = i
        while i <= count {
            tree[i] += delta
            i += i & (-i)
        }
    }

    /// Prefix sum [1..i] (1-indexed).
    public func prefixSum(upTo i: Int) -> T {
        var i = i
        var sum: T = 0
        while i > 0 {
            sum += tree[i]
            i -= i & (-i)
        }
        return sum
    }

    /// Range sum [l..r] (1-indexed, inclusive).
    public func rangeSum(from l: Int, to r: Int) -> T {
        prefixSum(upTo: r) - (l > 1 ? prefixSum(upTo: l - 1) : 0)
    }

    /// Find the smallest i such that prefixSum(upTo: i) >= value. O(log n).
    public func lowerBound(_ value: T) -> Int {
        var pos = 0
        var bitMask = 1 << Int(log2(Double(count)))
        var rem = value
        while bitMask > 0 {
            let next = pos + bitMask
            if next <= count && tree[next] < rem {
                rem -= tree[next]
                pos = next
            }
            bitMask >>= 1
        }
        return pos + 1
    }
}
