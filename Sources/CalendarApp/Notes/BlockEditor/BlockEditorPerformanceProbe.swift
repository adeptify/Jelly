import Foundation

struct BlockEditorPerformanceDistribution: Equatable, Sendable {
    let samplesMilliseconds: [Double]

    var p95Milliseconds: Double {
        guard !samplesMilliseconds.isEmpty else { return 0 }
        let sorted = samplesMilliseconds.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }

    var maxMilliseconds: Double { samplesMilliseconds.max() ?? 0 }
}

enum BlockEditorPerformanceProbe {
    static func measure(
        warmups: Int = 10,
        iterations: Int = 100,
        operation: () throws -> Void
    ) rethrows -> BlockEditorPerformanceDistribution {
        for _ in 0..<warmups { try operation() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try operation()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
        }
        return .init(samplesMilliseconds: samples)
    }
}
