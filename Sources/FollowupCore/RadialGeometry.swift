import Foundation

/// Geometry for the pie menu. Coordinates are y-down (screen/SwiftUI style),
/// and slice 0 is centered at the top, with slices running clockwise.
public enum RadialGeometry {
    /// Which slice the pointer is over, or nil while it's inside the dead zone.
    /// Anything past the inner radius counts, so a quick flick selects too.
    public static func slice(dx: Double, dy: Double, count: Int, innerRadius: Double) -> Int? {
        guard count > 0, hypot(dx, dy) >= innerRadius else { return nil }
        let span = 360.0 / Double(count)
        let degrees = atan2(dy, dx) * 180 / .pi // 0 = right, 90 = down
        var shifted = (degrees + 90 + span / 2).truncatingRemainder(dividingBy: 360)
        if shifted < 0 { shifted += 360 }
        return Int(shifted / span) % count
    }

    /// Center angle of a slice, in radians (y-down).
    public static func midAngle(index: Int, count: Int) -> Double {
        (-90 + 360.0 / Double(count) * Double(index)) * .pi / 180
    }

    /// Start and end angles of a slice, in degrees (y-down), with a small gap.
    public static func bounds(index: Int, count: Int, gap: Double = 1.5) -> (start: Double, end: Double) {
        let span = 360.0 / Double(count)
        let start = -90 - span / 2 + span * Double(index)
        return (start + gap, start + span - gap)
    }
}
