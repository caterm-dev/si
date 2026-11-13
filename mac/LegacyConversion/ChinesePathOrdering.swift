/// Swift adaptation of MSIME's lattice/cxx_sort.rs (GPL-3.0-only).
/// Heap selection and libc++ introsort deliberately compare only scores. Equal-score
/// movement affects which Chinese homophones survive; a stable secondary key changes it.
enum ChinesePathOrdering {
    static func makeHeap<T>(_ values: inout [T], count: Int, before: (T, T) -> Bool) {
        guard count > 1 else { return }
        for start in stride(from: (count - 2) / 2, through: 0, by: -1) {
            siftDown(&values, first: 0, last: count, start: start, before: before)
        }
    }

    static func siftDown<T>(_ values: inout [T], first: Int = 0, last: Int, start: Int,
                            before: (T, T) -> Bool) {
        let count = last - first
        guard count >= 2, start <= (count - 2) / 2 else { return }
        var start = start
        var child = 2 * start + 1
        if child + 1 < count, before(values[first + child], values[first + child + 1]) { child += 1 }
        if before(values[first + child], values[first + start]) { return }
        let top = values[first + start]
        while true {
            values[first + start] = values[first + child]
            start = child
            if child > (count - 2) / 2 { break }
            child = 2 * child + 1
            if child + 1 < count, before(values[first + child], values[first + child + 1]) { child += 1 }
            if before(values[first + child], top) { break }
        }
        values[first + start] = top
    }

    static func sortHeap<T>(_ values: inout [T], count: Int, before: (T, T) -> Bool) {
        sortHeap(&values, first: 0, last: count, before: before)
    }

    static func sort<T>(_ values: inout [T], before: (T, T) -> Bool) {
        guard !values.isEmpty else { return }
        let depth = 2 * (Int.bitWidth - 1 - values.count.leadingZeroBitCount)
        let count = values.count
        introsort(&values, first: 0, last: count, depth: depth, leftmost: true, before: before)
    }

    private static func sortHeap<T>(_ values: inout [T], first: Int, last: Int,
                                    before: (T, T) -> Bool) {
        guard last - first > 1 else { return }
        for end in stride(from: last, through: first + 2, by: -1) {
            popHeap(&values, first: first, last: end, before: before)
        }
    }

    private static func popHeap<T>(_ values: inout [T], first: Int, last: Int,
                                   before: (T, T) -> Bool) {
        let count = last - first
        guard count > 1 else { return }
        let top = values[first]
        var hole = 0
        var child = 0
        while true {
            child = 2 * child + 1
            if child + 1 < count, before(values[first + child], values[first + child + 1]) { child += 1 }
            values[first + hole] = values[first + child]
            hole = child
            if child > (count - 2) / 2 { break }
        }
        if hole == count - 1 {
            values[first + hole] = top
        } else {
            values[first + hole] = values[last - 1]
            hole += 1
            values[last - 1] = top
            siftUp(&values, first: first, last: first + hole, before: before)
        }
    }

    private static func siftUp<T>(_ values: inout [T], first: Int, last: Int,
                                  before: (T, T) -> Bool) {
        let count = last - first
        guard count > 1 else { return }
        var parent = (count - 2) / 2
        var position = count - 1
        guard before(values[first + parent], values[first + position]) else { return }
        let moved = values[first + position]
        while true {
            values[first + position] = values[first + parent]
            position = parent
            if parent == 0 { break }
            parent = (parent - 1) / 2
            if !before(values[first + parent], moved) { break }
        }
        values[first + position] = moved
    }

    private static func sort3<T>(_ values: inout [T], _ x: Int, _ y: Int, _ z: Int,
                                 before: (T, T) -> Bool) {
        if !before(values[y], values[x]) {
            if !before(values[z], values[y]) { return }
            values.swapAt(y, z)
            if before(values[y], values[x]) { values.swapAt(x, y) }
        } else if before(values[z], values[y]) {
            values.swapAt(x, z)
        } else {
            values.swapAt(x, y)
            if before(values[z], values[y]) { values.swapAt(y, z) }
        }
    }

    private static func smallSort<T>(_ values: inout [T], first: Int, last: Int,
                                     before: (T, T) -> Bool) {
        let count = last - first
        guard count >= 2 else { return }
        if count == 2 {
            if before(values[last - 1], values[first]) { values.swapAt(first, last - 1) }
            return
        }
        sort3(&values, first, first + 1, first + 2, before: before)
        if count >= 4, before(values[first + 3], values[first + 2]) {
            values.swapAt(first + 2, first + 3)
            if before(values[first + 2], values[first + 1]) {
                values.swapAt(first + 1, first + 2)
                if before(values[first + 1], values[first]) { values.swapAt(first, first + 1) }
            }
        }
        if count == 5, before(values[first + 4], values[first + 3]) {
            values.swapAt(first + 3, first + 4)
            if before(values[first + 3], values[first + 2]) {
                values.swapAt(first + 2, first + 3)
                if before(values[first + 2], values[first + 1]) {
                    values.swapAt(first + 1, first + 2)
                    if before(values[first + 1], values[first]) { values.swapAt(first, first + 1) }
                }
            }
        }
    }

    private static func insertionSort<T>(_ values: inout [T], first: Int, last: Int,
                                         guarded: Bool, before: (T, T) -> Bool) {
        guard last - first > 1 else { return }
        for index in first + 1..<last where before(values[index], values[index - 1]) {
            let moved = values[index]
            var previous = index - 1
            var position = index
            while true {
                values[position] = values[previous]
                position = previous
                if guarded && position == first { break }
                previous -= 1
                if !before(moved, values[previous]) { break }
            }
            values[position] = moved
        }
    }

    private static func incompleteInsertionSort<T>(_ values: inout [T], first: Int, last: Int,
                                                   before: (T, T) -> Bool) -> Bool {
        if last - first <= 5 {
            smallSort(&values, first: first, last: last, before: before)
            return true
        }
        var previous = first + 2
        sort3(&values, first, first + 1, previous, before: before)
        var moves = 0
        for index in previous + 1..<last {
            if before(values[index], values[previous]) {
                let moved = values[index]
                var scan = previous
                previous = index
                while true {
                    values[previous] = values[scan]
                    previous = scan
                    if previous == first { break }
                    scan -= 1
                    if !before(moved, values[scan]) { break }
                }
                values[previous] = moved
                moves += 1
                if moves == 8 { return index + 1 == last }
            }
            previous = index
        }
        return true
    }

    private static func partitionRight<T>(_ values: inout [T], first: Int, last: Int,
                                          before: (T, T) -> Bool) -> (pivot: Int, partitioned: Bool) {
        let begin = first
        let pivot = values[first]
        var first = first
        var last = last
        repeat { first += 1 } while before(values[first], pivot)
        if begin == first - 1 {
            while first < last {
                last -= 1
                if before(values[last], pivot) { break }
            }
        } else {
            repeat { last -= 1 } while !before(values[last], pivot)
        }
        let partitioned = first >= last
        while first < last {
            values.swapAt(first, last)
            repeat { first += 1 } while before(values[first], pivot)
            repeat { last -= 1 } while !before(values[last], pivot)
        }
        let pivotIndex = first - 1
        if begin != pivotIndex { values[begin] = values[pivotIndex] }
        values[pivotIndex] = pivot
        return (pivotIndex, partitioned)
    }

    private static func partitionLeft<T>(_ values: inout [T], first: Int, last: Int,
                                         before: (T, T) -> Bool) -> Int {
        let begin = first
        let end = last
        let pivot = values[first]
        var first = first
        var last = last
        if before(pivot, values[end - 1]) {
            repeat { first += 1 } while !before(pivot, values[first])
        } else {
            repeat { first += 1 } while first < end && !before(pivot, values[first])
        }
        if first < last {
            repeat { last -= 1 } while before(pivot, values[last])
        }
        while first < last {
            values.swapAt(first, last)
            repeat { first += 1 } while !before(pivot, values[first])
            repeat { last -= 1 } while before(pivot, values[last])
        }
        let pivotIndex = first - 1
        if begin != pivotIndex { values[begin] = values[pivotIndex] }
        values[pivotIndex] = pivot
        return first
    }

    private static func introsort<T>(_ values: inout [T], first: Int, last: Int, depth: Int,
                                     leftmost: Bool, before: (T, T) -> Bool) {
        var first = first
        var last = last
        var depth = depth
        var leftmost = leftmost
        while true {
            let count = last - first
            if count <= 5 {
                smallSort(&values, first: first, last: last, before: before)
                return
            }
            if count < 24 {
                insertionSort(&values, first: first, last: last, guarded: leftmost, before: before)
                return
            }
            if depth == 0 {
                for start in stride(from: (count - 2) / 2, through: 0, by: -1) {
                    siftDown(&values, first: first, last: last, start: start, before: before)
                }
                sortHeap(&values, first: first, last: last, before: before)
                return
            }
            depth -= 1
            let half = count / 2
            if count > 128 {
                sort3(&values, first, first + half, last - 1, before: before)
                sort3(&values, first + 1, first + half - 1, last - 2, before: before)
                sort3(&values, first + 2, first + half + 1, last - 3, before: before)
                sort3(&values, first + half - 1, first + half, first + half + 1, before: before)
                values.swapAt(first, first + half)
            } else {
                sort3(&values, first + half, first, last - 1, before: before)
            }
            if !leftmost && !before(values[first - 1], values[first]) {
                first = partitionLeft(&values, first: first, last: last, before: before)
                continue
            }
            let (pivot, partitioned) = partitionRight(&values, first: first, last: last, before: before)
            if partitioned {
                let leftSorted = incompleteInsertionSort(&values, first: first, last: pivot, before: before)
                if incompleteInsertionSort(&values, first: pivot + 1, last: last, before: before) {
                    if leftSorted { return }
                    last = pivot
                    continue
                } else if leftSorted {
                    first = pivot + 1
                    continue
                }
            }
            introsort(&values, first: first, last: pivot, depth: depth, leftmost: leftmost, before: before)
            leftmost = false
            first = pivot + 1
        }
    }
}

/// Streaming partial_sort selection in original edge-arrival order. The extra slot marks
/// overflow, matching MSIME's bounded collector; it is discarded when finishing the heap.
struct ChineseBeam<Value> {
    private struct Slot {
        let value: Value
        let score: Double
    }
    private var slots: [Slot] = []
    private let limit: Int

    init(limit: Int = 32) {
        self.limit = limit
        slots.reserveCapacity(limit + 1)
    }

    mutating func append(_ value: Value, score: Double) {
        let slot = Slot(value: value, score: score)
        if slots.count > limit {
            if score > slots[0].score {
                slots[0] = slot
                ChinesePathOrdering.siftDown(&slots, last: limit, start: 0, before: { $0.score > $1.score })
            }
        } else if slots.count < limit {
            slots.append(slot)
        } else if limit > 0 {
            ChinesePathOrdering.makeHeap(&slots, count: limit, before: { $0.score > $1.score })
            slots.append(slot)
            if score > slots[0].score {
                slots[0] = slot
                ChinesePathOrdering.siftDown(&slots, last: limit, start: 0, before: { $0.score > $1.score })
            }
        }
    }

    mutating func finish(terminal: Bool = false) -> [Value] {
        if slots.count > limit {
            ChinesePathOrdering.sortHeap(&slots, count: limit, before: { $0.score > $1.score })
            slots.removeLast()
        }
        if terminal { ChinesePathOrdering.sort(&slots, before: { $0.score > $1.score }) }
        return slots.map(\.value)
    }
}
