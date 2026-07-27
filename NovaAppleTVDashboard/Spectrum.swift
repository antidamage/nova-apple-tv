import SwiftUI

struct SpectrumValue: Equatable {
    var cursor: SpectrumCursor
    var preview: RGBColor
}

struct RGBColor: Codable, Equatable {
    var red: Int
    var green: Int
    var blue: Int

    var array: [Int] { [red, green, blue] }

    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

let candlelightSpectrum = SpectrumValue(
    cursor: SpectrumCursor(x: 0.08, y: 0.12),
    preview: RGBColor(red: 255, green: 147, blue: 41)
)

let warmWhiteSpectrum = SpectrumValue(
    cursor: SpectrumCursor(x: 0.09, y: 0.66),
    preview: RGBColor(red: 255, green: 214, blue: 170)
)

let whiteSpectrum = SpectrumValue(
    cursor: SpectrumCursor(x: 0.13, y: 0.96),
    preview: RGBColor(red: 255, green: 255, blue: 255)
)

func clamped(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
    min(upper, max(lower, value))
}

func adaptiveCandlelightSpectrum(sun: SunStatus?) -> SpectrumValue {
    sun?.state == "below_horizon" ? candlelightSpectrum : warmWhiteSpectrum
}

func adaptiveCandlelightBrightness(sun: SunStatus?) -> Double {
    sun?.state == "below_horizon" ? 60 : 100
}

func spectrumRGBAtPosition(x: Double, y: Double) -> RGBColor {
    let hue = clamped(x) * 359
    let boundedY = clamped(y)
    let saturation = 1 - boundedY
    let lightness = 0.5 + boundedY * 0.5
    return hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
}

func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> RGBColor {
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = lightness - c / 2
    let rgb: (Double, Double, Double)

    switch hue {
    case 0..<60:
        rgb = (c, x, 0)
    case 60..<120:
        rgb = (x, c, 0)
    case 120..<180:
        rgb = (0, c, x)
    case 180..<240:
        rgb = (0, x, c)
    case 240..<300:
        rgb = (x, 0, c)
    default:
        rgb = (c, 0, x)
    }

    return RGBColor(
        red: Int(((rgb.0 + m) * 255).rounded()),
        green: Int(((rgb.1 + m) * 255).rounded()),
        blue: Int(((rgb.2 + m) * 255).rounded())
    )
}
