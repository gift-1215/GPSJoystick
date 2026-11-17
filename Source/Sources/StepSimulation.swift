import Foundation

struct StepSimulation {
    private static let batchInterval: TimeInterval = 2
    private(set) var total = 0
    private var remainder = 0.0
    private var start: Date?
    private var end: Date?
    private var duration = 0.0
    private var steps = 0

    mutating func advance(meters: Double, elapsed: TimeInterval, stride: Double, now: Date) -> StepBatch? {
        var completed: StepBatch?
        if let end, now < end || now.timeIntervalSince(end) > 1 {
            completed = finish()
        }
        if start == nil {
            start = now.addingTimeInterval(-elapsed)
        }
        end = now
        duration += elapsed
        remainder += meters / stride
        let added = Int(remainder)
        remainder -= Double(added)
        steps += added
        total += added

        return duration >= Self.batchInterval ? finish() : completed
    }

    mutating func finish() -> StepBatch? {
        defer {
            start = nil
            end = nil
            duration = 0
            steps = 0
        }
        guard let start, let end, steps > 0 else { return nil }
        return StepBatch(id: UUID(), start: start, end: end, count: steps)
    }

    mutating func resetStrideProgress() {
        remainder = 0
    }
}
