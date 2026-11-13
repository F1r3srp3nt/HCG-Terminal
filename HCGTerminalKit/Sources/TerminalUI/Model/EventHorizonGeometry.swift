import Foundation

/// Decorative geometry for the Event Horizon background: sparse circuit traces, corner brackets
/// and fine tick marks, all near the outer edges so the centre and text-heavy regions stay quiet.
///
/// The geometry is generated once per detail level from a fixed seed and cached (`cached(_:)`).
/// It never depends on terminal output or other app state, so nothing is regenerated while the
/// app runs; the view only scales the cached points to its size.
///
/// Points are anchored to an edge: a fraction of the width/height plus an offset in points. That
/// keeps 45° bends at 45° on every screen shape and bounds how far anything reaches inward
/// (`maxDepth`), whatever the screen size.
public struct EventHorizonGeometry: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        /// Fraction of the width / height.
        public var fx: Double
        public var fy: Double
        /// Offset in points.
        public var dx: Double
        public var dy: Double

        public func resolved(width: Double, height: Double) -> (x: Double, y: Double) {
            (fx * width + dx, fy * height + dy)
        }
    }

    /// An open polyline, optionally ending in a small node (a via).
    public struct Path: Equatable, Sendable {
        public var points: [Point]
        public var endsInNode: Bool
    }

    /// Circuit traces running in from the edges.
    public var traces: [Path]
    /// Corner brackets and chamfer lines (architectural fragments).
    public var fragments: [Path]
    /// Short tick marks along the edges.
    public var ticks: [Path]

    public var isEmpty: Bool { traces.isEmpty && fragments.isEmpty && ticks.isEmpty }
    public var allPaths: [Path] { traces + fragments + ticks }

    /// Nothing is drawn further than this from the nearest edge (points).
    public static let maxDepth: Double = 84

    public static let empty = EventHorizonGeometry(traces: [], fragments: [], ticks: [])

    private static let subtle = make(.subtle)
    private static let enhanced = make(.enhanced)

    /// The cached geometry for a detail level (built once per process).
    public static func cached(_ detail: AppearanceSettings.BackgroundDetail) -> EventHorizonGeometry {
        switch detail {
        case .off: empty
        case .subtle: subtle
        case .enhanced: enhanced
        }
    }

    /// Builds the geometry deterministically. Exposed for tests; the app uses `cached(_:)`.
    public static func make(_ detail: AppearanceSettings.BackgroundDetail) -> EventHorizonGeometry {
        guard detail != .off else { return empty }
        var random = SeededRandom(seed: 0x4843_4720_4548) // "HCG EH"
        let traceCount = detail == .subtle ? 8 : 14

        var traces: [Path] = []
        // Spread traces over the four edges, clustered towards the corners where the screen is
        // usually emptiest, and away from the middle of each edge.
        for index in 0..<traceCount {
            let edge = Edge(rawValue: index % 4)!
            let nearStart = random.next() < 0.5
            let fraction = nearStart ? random.in(0.05...0.3) : random.in(0.7...0.95)
            traces.append(trace(edge: edge, fraction: fraction, random: &random))
        }

        var fragments: [Path] = []
        for corner in Corner.allCases {
            fragments.append(bracket(corner, inset: 10, arm: detail == .subtle ? 22 : 30))
            fragments.append(chamfer(corner, inset: 4, run: detail == .subtle ? 46 : 64))
        }

        var ticks: [Path] = []
        if detail == .enhanced {
            // Rows of fine ticks near two opposite corners.
            for (edge, fraction) in [(Edge.top, 0.78), (.bottom, 0.12), (.left, 0.62), (.right, 0.3)] {
                for step in 0..<6 {
                    let along = Double(step) * 7
                    ticks.append(Path(points: [
                        edge.point(fraction: fraction, along: along, inward: 6),
                        edge.point(fraction: fraction, along: along, inward: step == 0 ? 15 : 11),
                    ], endsInNode: false))
                }
            }
        }
        return EventHorizonGeometry(traces: traces, fragments: fragments, ticks: ticks)
    }

    // MARK: Construction

    enum Edge: Int {
        case top, right, bottom, left

        /// A point `inward` points from this edge, `along` points from `fraction` of its length.
        func point(fraction: Double, along: Double, inward: Double) -> Point {
            switch self {
            case .top: Point(fx: fraction, fy: 0, dx: along, dy: inward)
            case .bottom: Point(fx: fraction, fy: 1, dx: along, dy: -inward)
            case .left: Point(fx: 0, fy: fraction, dx: inward, dy: along)
            case .right: Point(fx: 1, fy: fraction, dx: -inward, dy: along)
            }
        }
    }

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var fx: Double { self == .topLeading || self == .bottomLeading ? 0 : 1 }
        var fy: Double { self == .topLeading || self == .topTrailing ? 0 : 1 }
        /// Direction into the screen.
        var sx: Double { fx == 0 ? 1 : -1 }
        var sy: Double { fy == 0 ? 1 : -1 }
    }

    /// Edge → straight in → 45° → along the edge → optional second 45° → node.
    private static func trace(edge: Edge, fraction: Double, random: inout SeededRandom) -> Path {
        let direction: Double = fraction < 0.5 ? 1 : -1 // run away from the nearest corner
        var along = 0.0
        var inward = -2.0 // start just outside the edge
        var points = [edge.point(fraction: fraction, along: along, inward: inward)]

        inward = random.in(14...34)
        points.append(edge.point(fraction: fraction, along: along, inward: inward))
        let diagonal = random.in(8...20)
        along += direction * diagonal
        inward += diagonal
        points.append(edge.point(fraction: fraction, along: along, inward: inward))
        along += direction * random.in(24...72)
        points.append(edge.point(fraction: fraction, along: along, inward: inward))
        if random.next() < 0.5 {
            let second = min(random.in(6...14), maxDepth - 6 - inward)
            along += direction * second
            inward += second
            points.append(edge.point(fraction: fraction, along: along, inward: inward))
            along += direction * random.in(10...26)
            points.append(edge.point(fraction: fraction, along: along, inward: inward))
        }
        return Path(points: points, endsInNode: true)
    }

    private static func bracket(_ corner: Corner, inset: Double, arm: Double) -> Path {
        func p(_ x: Double, _ y: Double) -> Point { Point(fx: corner.fx, fy: corner.fy, dx: corner.sx * x, dy: corner.sy * y) }
        return Path(points: [p(inset, inset + arm), p(inset, inset), p(inset + arm, inset)], endsInNode: false)
    }

    /// A 45° cut across the corner with a short run along the top or bottom edge.
    private static func chamfer(_ corner: Corner, inset: Double, run: Double) -> Path {
        func p(_ x: Double, _ y: Double) -> Point { Point(fx: corner.fx, fy: corner.fy, dx: corner.sx * x, dy: corner.sy * y) }
        return Path(points: [p(inset, inset + 26), p(inset + 18, inset + 8), p(inset + 18 + run, inset + 8)], endsInNode: false)
    }
}

/// Small deterministic generator (SplitMix64), so the geometry is identical on every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func `in`(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}
