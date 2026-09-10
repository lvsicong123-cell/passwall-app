import Testing
@testable import PasswallCore

@Suite("Precision scrolling")
struct ScrollAccumulatorTests {
    @Test("Sub-unit deltas are retained rather than discarded")
    func retainsFractionalDeltas() {
        var accumulator = ScrollAccumulator(unitsPerPoint: 1.5)

        #expect(accumulator.consume(points: 0.2) == 0)
        #expect(accumulator.consume(points: 0.2) == 0)
        #expect(accumulator.consume(points: 0.4) == 1)
        #expect(abs(accumulator.residual - 0.2) < 0.000_001)
    }

    @Test("Direction changes do not inherit opposing momentum")
    func directionChangeDropsOpposingResidual() {
        var accumulator = ScrollAccumulator(unitsPerPoint: 1.5)
        _ = accumulator.consume(points: 0.5)

        #expect(accumulator.consume(points: -0.5) == 0)
        #expect(accumulator.residual == -0.75)
    }
}
