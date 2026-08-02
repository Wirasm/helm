import Foundation

@testable import Helm

/// The colour arithmetic the palette tests assert against.
///
/// Spelled out rather than pulled in: these are three published formulas totalling about
/// twenty lines, and a dependency for twenty lines is how a test target starts owning a
/// package graph. Shared between `PaletteTests` and `AnsiPaletteTests` so the two cannot
/// drift into measuring "contrast" two different ways and both be right.
enum ColorMath {
    /// WCAG relative luminance.
    static func luminance(_ rgb: Palette.RGB) -> Double {
        let linear = { (channel: Double) in
            channel <= 0.039_28 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// WCAG contrast ratio, 1…21. Order-independent.
    static func contrast(_ first: Palette.RGB, _ second: Palette.RGB) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The same, resolved for one appearance — the form nearly every assertion wants.
    static func contrast(
        _ token: Palette.Token, on background: Palette.Token, in appearance: Palette.Appearance
    ) -> Double {
        contrast(token.value(in: appearance), background.value(in: appearance))
    }

    /// HSV hue in degrees, 0…360. Meaningless below a little saturation, which is why the
    /// grey entries are asserted on `saturation` instead.
    static func hue(_ rgb: Palette.RGB) -> Double {
        let high = max(rgb.red, rgb.green, rgb.blue)
        let low = min(rgb.red, rgb.green, rgb.blue)
        let delta = high - low
        guard delta > 0 else { return 0 }
        let degrees: Double =
            switch high {
            case rgb.red: 60 * (((rgb.green - rgb.blue) / delta).truncatingRemainder(dividingBy: 6))
            case rgb.green: 60 * (2 + (rgb.blue - rgb.red) / delta)
            default: 60 * (4 + (rgb.red - rgb.green) / delta)
            }
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// HSV saturation, 0…1.
    static func saturation(_ rgb: Palette.RGB) -> Double {
        let high = max(rgb.red, rgb.green, rgb.blue)
        guard high > 0 else { return 0 }
        return (high - min(rgb.red, rgb.green, rgb.blue)) / high
    }

    /// Whether a hue sits inside a band, handling the wrap red lives across.
    static func hue(_ value: Double, isWithin band: ClosedRange<Double>) -> Bool {
        guard band.lowerBound < 0 else { return band.contains(value) }
        return value >= band.lowerBound + 360 || value <= band.upperBound
    }
}
