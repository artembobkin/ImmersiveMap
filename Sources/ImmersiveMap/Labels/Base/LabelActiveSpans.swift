// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The labels of the working set a frame works on, as spans of the set's
/// indices: in each run, the head of labels whose zoom the camera has
/// reached, and behind it the labels still fading out since the camera
/// left their zoom. The rest of the run waits for a deeper zoom and costs
/// the frame nothing: no projection, no collision, no fade.
///
/// A tile at the deepest zoom carries every label down to the street (the
/// cafés, the shops, a number on every house), and a tilted camera brings
/// the nine labelled tiles into the frame at once, so the run is long
/// while the head the camera's zoom shows is a fraction of it. A tile's
/// labels are ordered by the zoom they show from (`TileTextLabelsBuilder`),
/// which is what makes the labels a zoom shows a head of the run, found by
/// a binary search.
///
/// A label leaves the spans once it is fully faded out and wants to stay
/// so: its alpha and its runtime meta are then 0, which is what the
/// shaders hide a label by, so leaving it untouched keeps it hidden.
struct LabelActiveSpans {
    /// The spans of the frame, one per tile run that has any, in the set's
    /// order.
    private(set) var spans: [Range<Int>] = []
    private var runs: [Range<Int>] = []
    /// Per run, the end of the labels the camera's zoom shows.
    private var headEnds: [Int] = []
    /// Per run, the end of the labels still lit behind the head: fading,
    /// or wanting to show. Never short of the head.
    private var litEnds: [Int] = []
    /// Whether the set changed since the lit ends were found: a run that
    /// survived carries its fades, and the next resolve finds where its
    /// lit labels end from the alphas it is given.
    private var findsLitEnds = false

    /// The total of the spans' labels.
    var count: Int {
        var total = 0
        for span in spans {
            total += span.count
        }
        return total
    }

    /// Binds the spans to a new set. A run that survived carries its
    /// fades with it, so the next resolve looks for its lit labels behind
    /// the head in the alphas it is given.
    mutating func rebind(runs: [Range<Int>]) {
        self.runs = runs
        headEnds = runs.map(\.upperBound)
        litEnds = runs.map(\.upperBound)
        spans = runs.filter { $0.isEmpty == false }
        findsLitEnds = true
    }

    mutating func reset() {
        self = LabelActiveSpans()
    }

    /// The frame's spans for a camera zoom: each run's head of the labels
    /// whose minimum zoom is at or below `cameraZoom`, stretched over the
    /// labels behind it still lit. `alphas` are the labels' fades, read
    /// after a change of the set to find the lit labels it carried.
    mutating func resolve(inputs: UnsafeBufferPointer<BaseLabelPresentationInput>,
                          alphas: UnsafeBufferPointer<Float>,
                          cameraZoom: Float) {
        spans.removeAll(keepingCapacity: true)
        let inputCount = inputs.count
        var runIndex = 0
        while runIndex < runs.count {
            let run = runs[runIndex]
            let lower = min(run.lowerBound, inputCount)
            let upper = min(run.upperBound, inputCount)
            // The first label of the run whose zoom is past the camera's.
            var low = lower
            var high = upper
            while low < high {
                let middle = (low + high) / 2
                if inputs[middle].minCameraZoom <= cameraZoom {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            headEnds[runIndex] = low
            if findsLitEnds {
                var lit = min(upper, alphas.count)
                while lit > low, alphas[lit - 1] <= 0 {
                    lit -= 1
                }
                litEnds[runIndex] = max(lit, low)
            }
            let end = max(low, min(litEnds[runIndex], upper))
            if end > lower {
                spans.append(lower..<end)
            }
            runIndex += 1
        }
        findsLitEnds = false
    }

    /// After the frame's fades: where each run's lit labels end, the last
    /// label behind the head with an alpha or a target above zero. A run
    /// whose labels behind the head are all dark shrinks to its head for
    /// the next frame.
    mutating func updateLitEnds(alphas: UnsafeBufferPointer<Float>, targets: UnsafeBufferPointer<Bool>) {
        var runIndex = 0
        while runIndex < runs.count {
            let head = headEnds[runIndex]
            var end = min(min(litEnds[runIndex], runs[runIndex].upperBound), min(alphas.count, targets.count))
            while end > head, alphas[end - 1] <= 0, targets[end - 1] == false {
                end -= 1
            }
            litEnds[runIndex] = max(end, head)
            runIndex += 1
        }
    }
}
