// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md §7). Chinese Whispers over a k-nearest-neighbour
// graph, after Lap's t_cluster.rs, with the changes §7 lists: a fixed seed, a bounded heap for the neighbour lists, no edge between
// two faces of one photo, and a cancel and time budget. Pure: it reads vectors and returns groups, it writes nothing.
import Foundation

public struct ClusterInput: Sendable {
    public var id: Int64
    public var path: String
    public var embedding: [Float]
    public init(id: Int64, path: String, embedding: [Float]) { (self.id, self.path, self.embedding) = (id, path, embedding) }
}

/// SplitMix64: the same seed gives the same order on every machine (Swift's own generator is not seedable).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public enum FaceClustering {
    public struct Cancelled: Error {}

    /// The groups as lists of indices into `faces`, each sorted, the groups ordered by their first index. Singletons are included
    /// (the caller decides what a group must hold). `shouldStop` is polled once per face and once per round; it throws `Cancelled`.
    public static func cluster(_ faces: [ClusterInput], threshold: Double, neighbours: Int, rounds: Int, seed: UInt64,
                               shouldStop: () -> Bool = { false }) throws -> [[Int]] {
        let n = faces.count
        guard n > 0 else { return [] }
        let dimension = faces.map { $0.embedding.count }.max() ?? 0
        var flat = [Float](repeating: 0, count: n * dimension)
        for (i, face) in faces.enumerated() {
            for (j, value) in face.embedding.prefix(dimension).enumerated() { flat[i * dimension + j] = value }
        }

        // Neighbour lists: for each face the `neighbours` most similar faces above the threshold, kept in a bounded min-heap.
        // An edge is kept when either side lists the other, so the graph is symmetric. Two faces of one photo are never linked.
        var adjacency = [[Int: Float]](repeating: [:], count: n)
        // The photo of each face as a number: the pair loop below runs n² times, and comparing two Strings there costs more than the dot product.
        var photoNumbers: [String: Int] = [:]
        let photo: [Int] = faces.map { face in
            if let number = photoNumbers[face.path] { return number }
            photoNumbers[face.path] = photoNumbers.count
            return photoNumbers.count - 1
        }
        let k = max(1, neighbours)
        try flat.withUnsafeBufferPointer { vectors in
            var heap = BoundedHeap(capacity: k)
            for i in 0..<n {
                if shouldStop() { throw Cancelled() }
                heap.removeAll()
                let a = vectors.baseAddress! + i * dimension
                for j in 0..<n where j != i && photo[j] != photo[i] {
                    let b = vectors.baseAddress! + j * dimension
                    var sum: Float = 0
                    for d in 0..<dimension { sum += a[d] * b[d] }
                    if Double(sum) >= threshold { heap.push(similarity: sum, index: j) }
                }
                for (similarity, j) in heap.items {
                    adjacency[i][j] = similarity
                    adjacency[j][i] = similarity
                }
            }
        }

        // Chinese Whispers: each face repeatedly takes the label with the most weight among its neighbours (weight = similarity²,
        // so weak links count less). Ties go to the smaller label, and the visiting order is shuffled from the seed.
        var label = Array(0..<n)
        var order = Array(0..<n)
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<max(1, rounds) {
            if shouldStop() { throw Cancelled() }
            order.shuffle(using: &generator)
            var changed = false
            for node in order where !adjacency[node].isEmpty {
                var weights: [Int: Float] = [:]
                for (other, similarity) in adjacency[node] { weights[label[other], default: 0] += similarity * similarity }
                var best = label[node]
                var bestWeight = weights[best] ?? -1
                for (candidate, weight) in weights where weight > bestWeight || (weight == bestWeight && candidate < best) {
                    best = candidate; bestWeight = weight
                }
                if best != label[node] { label[node] = best; changed = true }
            }
            if !changed { break }
        }

        var groups: [Int: [Int]] = [:]
        for (i, l) in label.enumerated() { groups[l, default: []].append(i) }
        return groups.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// Keeps the `capacity` largest similarities seen, as a min-heap on similarity (the smallest kept is at the top and is the one replaced).
    struct BoundedHeap {
        let capacity: Int
        private(set) var items: [(Float, Int)] = []
        init(capacity: Int) { self.capacity = capacity; items.reserveCapacity(capacity) }
        mutating func removeAll() { items.removeAll(keepingCapacity: true) }

        mutating func push(similarity: Float, index: Int) {
            if items.count < capacity {
                items.append((similarity, index))
                var child = items.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard items[child].0 < items[parent].0 else { break }
                    items.swapAt(child, parent); child = parent
                }
            } else if similarity > items[0].0 {
                items[0] = (similarity, index)
                var parent = 0
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var smallest = parent
                    if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
                    if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
                    if smallest == parent { break }
                    items.swapAt(parent, smallest); parent = smallest
                }
            }
        }
    }
}
