/// Summary statistics over a set of samples (nanoseconds, or any other unit).
///
/// Percentiles use linear interpolation between the closest ranks
/// (the "R-7" / NumPy default definition): for `n` sorted samples the
/// p-th percentile sits at fractional index `(n - 1) * p / 100`.
/// The median is the 50th percentile, so for an even count it is the mean
/// of the two middle samples.
struct Summary: Equatable, Sendable {
    var count: Int
    var min: Double
    var max: Double
    var mean: Double
    var median: Double
    var p90: Double
    var p99: Double

    /// Returns `nil` for an empty sample set.
    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        self.init(sorted: samples.sorted())
    }

    /// `sorted` must be non-empty and ascending.
    init(sorted: [Double]) {
        precondition(!sorted.isEmpty, "Summary needs at least one sample")
        count = sorted.count
        min = sorted[0]
        max = sorted[sorted.count - 1]
        var total = 0.0
        for value in sorted { total += value }
        mean = total / Double(sorted.count)
        median = Stats.percentile(sorted: sorted, 50)
        p90 = Stats.percentile(sorted: sorted, 90)
        p99 = Stats.percentile(sorted: sorted, 99)
    }
}

enum Stats {
    /// The `p`-th percentile (0...100) of ascending `sorted` samples, by linear
    /// interpolation between closest ranks. `p` is clamped to 0...100.
    static func percentile(sorted: [Double], _ p: Double) -> Double {
        precondition(!sorted.isEmpty, "percentile of an empty sample set")
        if sorted.count == 1 { return sorted[0] }
        let clamped = Swift.min(Swift.max(p, 0), 100)
        let rank = Double(sorted.count - 1) * clamped / 100
        let lower = Int(rank.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let fraction = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Nanoseconds in a `Duration`, as a `Double`.
    static func nanoseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9
    }

    /// Relative change of `current` against `baseline`, in percent
    /// (positive means `current` is larger). Returns 0 when `baseline` is 0.
    static func percentChange(baseline: Double, current: Double) -> Double {
        guard baseline != 0 else { return 0 }
        return (current - baseline) / baseline * 100
    }
}
