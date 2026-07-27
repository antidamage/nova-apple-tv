import Foundation
import SwiftUI

// Status orb modules — tvOS implementation of the shared cross-platform
// contract defined in nova-ha-dashboard/lib/orb-modules.ts and SPEC.md
// ("Status Orb Modules").
//
// A module is a declarative JSON document describing the orb's entire draw
// stack as ordered layers. This file contains:
//   1. The decodable model (lenient like the web normalizer: values are
//      clamped, unknown layer types are skipped, invalid documents are
//      rejected whole so the renderer falls back to the classic built-in).
//   2. The built-in modules, embedded as the exact JSON the web client
//      compiles in, decoded through the same path as fetched modules.
//   3. The per-frame palette resolved from the shared avatar theme.
//   4. The animation state for arcField/lineField layers (identical motion
//      model to the web renderer; angles in turns, speeds in turns/second,
//      line positions in track fractions).
//   5. The GraphicsContext renderer that interprets a module each frame.
//
// Contract conventions:
//   - Unit space: orb radius = 1.0, center (0,0), +x right, +y down. Every
//     length in a module is a fraction of the orb radius.
//   - Angles/sweeps are in TURNS (0..1 per revolution, clockwise from
//     3 o'clock); converted to radians only at draw time.
//   - Blend modes map 1:1 onto GraphicsContext blend modes (normal/.normal,
//     additive/.plusLighter, screen/.screen, multiply/.multiply).

// MARK: - Decode helpers

private func decodeClamped(
    _ container: KeyedDecodingContainer<OrbCodingKey>,
    _ key: String,
    default defaultValue: Double,
    _ lower: Double,
    _ upper: Double
) -> Double {
    // `try?` flattens, so the binding fails on a decode throw OR an absent
    // key — both fall back to the default.
    guard let value = try? container.decodeIfPresent(Double.self, forKey: OrbCodingKey(key)) else {
        return defaultValue
    }
    return clamped(value, lower, upper)
}

/// Free-form string keys so the model structs can decode without declaring
/// per-struct CodingKeys enums for every optional field.
struct OrbCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - Color references

/// Theme color slots a module layer may reference; resolved per frame from
/// the shared avatar theme (see OrbPalette).
enum OrbThemeSlot: String, Equatable {
    case gradientCenter, gradientOuter, gradientAlert
    case line1, line2, line3
    case gymNumber, innerShadow
}

/// A layer color: a theme slot or a hard-coded hex value, an optional alpha
/// multiplier, and an optional slot to pulse toward while the gym alert is
/// active. Invalid refs degrade to opaque white (matching the web
/// normalizer) so a bad color is visible rather than invisible.
struct OrbColorRef: Equatable, Decodable {
    var theme: OrbThemeSlot?
    var hexRGB: ThemeRGB?
    var alpha: Double?
    var alertTheme: OrbThemeSlot?

    init(from decoder: Decoder) throws {
        // Note: `try?` flattens optionals, so each binding below yields the
        // non-optional decoded value (binding fails on throw OR absent key).
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        if let slotRaw = try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("theme")),
           let slot = OrbThemeSlot(rawValue: slotRaw) {
            theme = slot
        } else if let hex = try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("hex")),
                  let rgb = parseHexColor(hex) {
            hexRGB = rgb
        } else {
            hexRGB = ThemeRGB(red: 255, green: 255, blue: 255)
        }
        if let value = try? container?.decodeIfPresent(Double.self, forKey: OrbCodingKey("alpha")) {
            alpha = clamped(value, 0, 1)
        }
        if let alertRaw = try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("alertTheme")),
           let slot = OrbThemeSlot(rawValue: alertRaw) {
            alertTheme = slot
        }
    }
}

/// Parse #rgb or #rrggbb into rgb channels; nil for anything else.
private func parseHexColor(_ value: String) -> ThemeRGB? {
    var raw = value
    guard raw.hasPrefix("#") else { return nil }
    raw.removeFirst()
    if raw.count == 3 {
        raw = raw.map { "\($0)\($0)" }.joined()
    }
    guard raw.count == 6, let bits = UInt32(raw, radix: 16) else { return nil }
    return ThemeRGB(
        red: Double((bits >> 16) & 0xFF),
        green: Double((bits >> 8) & 0xFF),
        blue: Double(bits & 0xFF)
    )
}

struct OrbGradientStop: Equatable, Decodable {
    var at: Double
    var color: OrbColorRef

    init(at: Double, color: OrbColorRef) {
        self.at = clamped(at)
        self.color = color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OrbCodingKey.self)
        at = decodeClamped(container, "at", default: 0, 0, 1)
        color = (try? container.decode(OrbColorRef.self, forKey: OrbCodingKey("color"))) ?? whiteColorRef()
    }
}

/// Builds the "opaque white" fallback ref outside of Decodable contexts.
private func whiteColorRef() -> OrbColorRef {
    // ## delimiters because the payload contains `"#` (a hex color after a
    // quote), which would terminate a plain #"..."# raw string early.
    let data = Data(##"{"hex": "#ffffff"}"##.utf8)
    // Decoding a constant literal cannot fail; the forced try is safe.
    return try! JSONDecoder().decode(OrbColorRef.self, from: data)
}

// MARK: - Geometry primitives

struct OrbPoint: Equatable, Decodable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        x = container.map { decodeClamped($0, "x", default: 0, -4, 4) } ?? 0
        y = container.map { decodeClamped($0, "y", default: 0, -4, 4) } ?? 0
    }
}

struct OrbGradientCircle: Equatable, Decodable {
    var x: Double
    var y: Double
    var radius: Double

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        x = container.map { decodeClamped($0, "x", default: 0, -4, 4) } ?? 0
        y = container.map { decodeClamped($0, "y", default: 0, -4, 4) } ?? 0
        radius = container.map { decodeClamped($0, "radius", default: 0, 0, 8) } ?? 0
    }
}

struct OrbTrack: Equatable, Decodable {
    var from: OrbPoint
    var to: OrbPoint

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        from = (try? container?.decode(OrbPoint.self, forKey: OrbCodingKey("from"))) ?? OrbPoint(x: -1, y: 0)
        to = (try? container?.decode(OrbPoint.self, forKey: OrbCodingKey("to"))) ?? OrbPoint(x: 1, y: 0)
    }
}

/// A numeric module parameter may be a literal or a binding to one of the
/// module's declared settings. Unknown bindings degrade to the caller's
/// fallback instead of invalidating the layer.
enum OrbSettingValue: Equatable, Decodable {
    case literal(Double)
    case setting(String)

    init(from decoder: Decoder) throws {
        if let number = try? decoder.singleValueContainer().decode(Double.self), number.isFinite {
            self = .literal(number)
            return
        }
        let container = try decoder.container(keyedBy: OrbCodingKey.self)
        let id = try container.decode(String.self, forKey: OrbCodingKey("setting"))
        guard isValidOrbModuleID(id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid orb setting binding"))
        }
        self = .setting(id)
    }

    func resolved(settings: [String: Double], fallback: Double) -> Double {
        switch self {
        case .literal(let value):
            return value.isFinite ? value : fallback
        case .setting(let id):
            return settings[id] ?? fallback
        }
    }
}

struct OrbRingTurbulence: Equatable, Decodable {
    var fibers: OrbSettingValue?
    var chaos: OrbSettingValue?
    var weave: OrbSettingValue?
    var speed: OrbSettingValue?
    var pulse: OrbSettingValue?
    var softness: OrbSettingValue?
}

// MARK: - Shared layer fields

enum OrbBlendModeSpec: String, Equatable {
    case normal, additive, screen, multiply

    /// The 1:1 cross-platform blend mapping (the reason the module format
    /// restricts itself to these four modes).
    var graphicsBlendMode: GraphicsContext.BlendMode {
        switch self {
        case .normal: return .normal
        case .additive: return .plusLighter
        case .screen: return .screen
        case .multiply: return .multiply
        }
    }
}

enum OrbStrokeCap: String, Equatable {
    case round, butt

    var lineCap: CGLineCap {
        self == .butt ? .butt : .round
    }
}

/// Optional opacity oscillation; with alertOnly the layer is hidden entirely
/// until the gym alert activates (alert-flash layers).
struct OrbLayerPulse: Equatable {
    var period: Double
    var min: Double
    var max: Double
    var alertOnly: Bool
}

/// Fields shared by every layer type, decoded once per layer.
struct OrbLayerBase: Equatable {
    var enabled: Bool
    var blend: OrbBlendModeSpec
    var opacity: Double
    var clip: Bool
    var glow: Double
    var pulse: OrbLayerPulse?

    init(container: KeyedDecodingContainer<OrbCodingKey>?) {
        enabled = (try? container?.decodeIfPresent(Bool.self, forKey: OrbCodingKey("enabled"))) ?? true
        let blendRaw = (try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("blend"))) ?? nil
        blend = blendRaw.flatMap(OrbBlendModeSpec.init(rawValue:)) ?? .normal
        opacity = container.map { decodeClamped($0, "opacity", default: 1, 0, 1) } ?? 1
        clip = (try? container?.decodeIfPresent(Bool.self, forKey: OrbCodingKey("clip"))) ?? false
        glow = container.map { decodeClamped($0, "glow", default: 0, 0, 4) } ?? 0
        pulse = nil
        if let container,
           container.contains(OrbCodingKey("pulse")),
           let pulseContainer = try? container.nestedContainer(keyedBy: OrbCodingKey.self, forKey: OrbCodingKey("pulse")) {
            let minValue = decodeClamped(pulseContainer, "min", default: 0, 0, 1)
            let maxValue = decodeClamped(pulseContainer, "max", default: 1, 0, 1)
            pulse = OrbLayerPulse(
                period: decodeClamped(pulseContainer, "period", default: 1.2, 0.05, 60),
                min: Swift.min(minValue, maxValue),
                max: Swift.max(minValue, maxValue),
                alertOnly: (try? pulseContainer.decodeIfPresent(Bool.self, forKey: OrbCodingKey("alertOnly"))) ?? false
            )
        }
    }
}

private func decodeStops(_ container: KeyedDecodingContainer<OrbCodingKey>?) -> [OrbGradientStop] {
    let stops = ((try? container?.decodeIfPresent([OrbGradientStop].self, forKey: OrbCodingKey("stops"))) ?? nil) ?? []
    // A gradient needs at least one stop; default to white so a malformed
    // layer is visible rather than silently invisible.
    if stops.isEmpty {
        // ## delimiters: the payload contains `"#` (hex color after a quote).
        let data = Data(##"[{"at": 0, "color": {"hex": "#ffffff"}}]"##.utf8)
        return (try? JSONDecoder().decode([OrbGradientStop].self, from: data)) ?? []
    }
    return stops.sorted { $0.at < $1.at }
}

private func decodeColors(_ container: KeyedDecodingContainer<OrbCodingKey>?) -> [OrbColorRef] {
    let colors = ((try? container?.decodeIfPresent([OrbColorRef].self, forKey: OrbCodingKey("colors"))) ?? nil) ?? []
    if !colors.isEmpty {
        return colors
    }
    // Default to the three theme line colors, mirroring the web normalizer.
    let data = Data(#"[{"theme": "line1"}, {"theme": "line2"}, {"theme": "line3"}]"#.utf8)
    return (try? JSONDecoder().decode([OrbColorRef].self, from: data)) ?? []
}

// MARK: - Layer types

/// `disc` — filled circle/ellipse with a radial gradient.
struct OrbDiscLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var center: OrbPoint
    var radius: Double
    var scaleY: Double
    var rotation: Double
    var gradientFrom: OrbGradientCircle?
    var gradientTo: OrbGradientCircle?
    var stops: [OrbGradientStop]

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        center = (try? container?.decodeIfPresent(OrbPoint.self, forKey: OrbCodingKey("center")))
            .flatMap { $0 } ?? OrbPoint(x: 0, y: 0)
        radius = container.map { decodeClamped($0, "radius", default: 1, 0.001, 4) } ?? 1
        scaleY = container.map { decodeClamped($0, "scaleY", default: 1, 0.01, 4) } ?? 1
        rotation = container.map { decodeClamped($0, "rotation", default: 0, -1, 1) } ?? 0
        gradientFrom = (try? container?.decodeIfPresent(OrbGradientCircle.self, forKey: OrbCodingKey("gradientFrom"))).flatMap { $0 }
        gradientTo = (try? container?.decodeIfPresent(OrbGradientCircle.self, forKey: OrbCodingKey("gradientTo"))).flatMap { $0 }
        stops = decodeStops(container)
    }
}

/// `ring` — stroked full circle.
struct OrbRingLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var radius: Double
    var width: Double
    var color: OrbColorRef
    var turbulence: OrbRingTurbulence?

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        radius = container.map { decodeClamped($0, "radius", default: 1, 0.001, 4) } ?? 1
        width = container.map { decodeClamped($0, "width", default: 0.02, 0.001, 2) } ?? 0.02
        color = ((try? container?.decodeIfPresent(OrbColorRef.self, forKey: OrbCodingKey("color"))) ?? nil) ?? whiteColorRef()
        turbulence = (try? container?.decodeIfPresent(OrbRingTurbulence.self, forKey: OrbCodingKey("turbulence"))).flatMap { $0 }
    }
}

/// `arc` — stroked partial arc with a linear gradient along its sweep.
struct OrbArcLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var radius: Double
    var width: Double
    var from: Double
    var to: Double
    var cap: OrbStrokeCap
    var reverse: Bool
    var stops: [OrbGradientStop]

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        radius = container.map { decodeClamped($0, "radius", default: 1, 0.001, 4) } ?? 1
        width = container.map { decodeClamped($0, "width", default: 0.02, 0.001, 2) } ?? 0.02
        from = container.map { decodeClamped($0, "from", default: 0, -4, 4) } ?? 0
        to = container.map { decodeClamped($0, "to", default: 0.25, -4, 4) } ?? 0.25
        let capRaw = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("cap"))) ?? nil) ?? "round"
        cap = OrbStrokeCap(rawValue: capRaw) ?? .round
        reverse = (try? container?.decodeIfPresent(Bool.self, forKey: OrbCodingKey("reverse"))) ?? false
        stops = decodeStops(container)
    }
}

/// `arcField` — the animated, load-reactive swarm of glowing arc segments.
struct OrbArcFieldLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var count: Int
    var radiusMin: Double
    var radiusMax: Double
    var ringsDistribution: Bool
    var ringCount: Int
    var ringJitter: Double
    var widthMin: Double
    var widthMax: Double
    var colors: [OrbColorRef]
    var randomColors: Bool
    var cap: OrbStrokeCap
    var idleSweepMin: Double
    var idleSweepMax: Double
    var loadSweep: Double
    var speedMin: Double
    var speedMax: Double
    var loadSpeed: Double
    var sweepEase: Double
    var velocityEase: Double
    var resampleMin: Double
    var resampleJitter: Double

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        count = Int(container.map { decodeClamped($0, "count", default: 50, 1, 400) } ?? 50)
        radiusMin = container.map { decodeClamped($0, "radiusMin", default: 0.1, 0, 4) } ?? 0.1
        radiusMax = Swift.max(radiusMin, container.map { decodeClamped($0, "radiusMax", default: 0.95, 0, 4) } ?? 0.95)
        let distribution = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("distribution"))) ?? nil) ?? "spread"
        ringsDistribution = distribution == "rings"
        ringCount = Int(container.map { decodeClamped($0, "ringCount", default: 3, 1, 32) } ?? 3)
        ringJitter = container.map { decodeClamped($0, "ringJitter", default: 0, 0, 1) } ?? 0
        widthMin = container.map { decodeClamped($0, "widthMin", default: 0.01, 0.001, 1) } ?? 0.01
        widthMax = Swift.max(widthMin, container.map { decodeClamped($0, "widthMax", default: 0.08, 0.001, 1) } ?? 0.08)
        colors = decodeColors(container)
        let colorMode = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("colorMode"))) ?? nil) ?? "cycle"
        randomColors = colorMode == "random"
        let capRaw = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("cap"))) ?? nil) ?? "round"
        cap = OrbStrokeCap(rawValue: capRaw) ?? .round
        idleSweepMin = container.map { decodeClamped($0, "idleSweepMin", default: 0.00025, 0, 1) } ?? 0.00025
        idleSweepMax = Swift.max(idleSweepMin, container.map { decodeClamped($0, "idleSweepMax", default: 0.001, 0, 1) } ?? 0.001)
        loadSweep = container.map { decodeClamped($0, "loadSweep", default: 1, 0, 1) } ?? 1
        speedMin = container.map { decodeClamped($0, "speedMin", default: 0.0557, 0, 4) } ?? 0.0557
        speedMax = container.map { decodeClamped($0, "speedMax", default: 0.1194, 0, 4) } ?? 0.1194
        loadSpeed = container.map { decodeClamped($0, "loadSpeed", default: 0.2546, 0, 4) } ?? 0.2546
        sweepEase = container.map { decodeClamped($0, "sweepEase", default: 1, 0.01, 30) } ?? 1
        velocityEase = container.map { decodeClamped($0, "velocityEase", default: 1, 0.01, 30) } ?? 1
        resampleMin = container.map { decodeClamped($0, "resampleMin", default: 0.8, 0.05, 60) } ?? 0.8
        resampleJitter = container.map { decodeClamped($0, "resampleJitter", default: 0.6, 0, 60) } ?? 0.6
    }
}

/// `line` — a single stroked straight segment.
struct OrbLineLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var from: OrbPoint
    var to: OrbPoint
    var width: Double
    var color: OrbColorRef
    var cap: OrbStrokeCap

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        from = ((try? container?.decodeIfPresent(OrbPoint.self, forKey: OrbCodingKey("from"))) ?? nil) ?? OrbPoint(x: -1, y: 0)
        to = ((try? container?.decodeIfPresent(OrbPoint.self, forKey: OrbCodingKey("to"))) ?? nil) ?? OrbPoint(x: 1, y: 0)
        width = container.map { decodeClamped($0, "width", default: 0.02, 0.001, 2) } ?? 0.02
        color = ((try? container?.decodeIfPresent(OrbColorRef.self, forKey: OrbCodingKey("color"))) ?? nil) ?? whiteColorRef()
        let capRaw = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("cap"))) ?? nil) ?? "round"
        cap = OrbStrokeCap(rawValue: capRaw) ?? .round
    }
}

/// `polygon` — stroked or filled polygon/polyline from explicit points.
struct OrbPolygonLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var points: [OrbPoint]
    var color: OrbColorRef
    var fill: Bool
    var width: Double
    var close: Bool

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        points = ((try? container?.decodeIfPresent([OrbPoint].self, forKey: OrbCodingKey("points"))) ?? nil) ?? []
        color = ((try? container?.decodeIfPresent(OrbColorRef.self, forKey: OrbCodingKey("color"))) ?? nil) ?? whiteColorRef()
        fill = (try? container?.decodeIfPresent(Bool.self, forKey: OrbCodingKey("fill"))) ?? false
        width = container.map { decodeClamped($0, "width", default: 0.02, 0.001, 2) } ?? 0.02
        close = (try? container?.decodeIfPresent(Bool.self, forKey: OrbCodingKey("close"))) ?? true
        // A polygon needs at least three vertices (mirrors the web
        // normalizer, which rejects smaller shapes).
        if points.count < 3 {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "polygon needs at least 3 points"
            ))
        }
    }
}

/// `lineField` — animated segments riding back and forth along straight
/// tracks, the linear counterpart to arcField.
struct OrbLineFieldLayer: Equatable, Decodable {
    var base: OrbLayerBase
    var count: Int
    var tracks: [OrbTrack]
    var widthMin: Double
    var widthMax: Double
    var colors: [OrbColorRef]
    var randomColors: Bool
    var cap: OrbStrokeCap
    var idleLengthMin: Double
    var idleLengthMax: Double
    var loadLength: Double
    var speedMin: Double
    var speedMax: Double
    var loadSpeed: Double
    var lengthEase: Double
    var velocityEase: Double
    var resampleMin: Double
    var resampleJitter: Double

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: OrbCodingKey.self)
        base = OrbLayerBase(container: container)
        count = Int(container.map { decodeClamped($0, "count", default: 6, 1, 400) } ?? 6)
        let decodedTracks = ((try? container?.decodeIfPresent([OrbTrack].self, forKey: OrbCodingKey("tracks"))) ?? nil) ?? []
        if decodedTracks.isEmpty {
            // Default single horizontal diameter, mirroring the web model.
            let data = Data(#"[{"from": {"x": -1, "y": 0}, "to": {"x": 1, "y": 0}}]"#.utf8)
            tracks = (try? JSONDecoder().decode([OrbTrack].self, from: data)) ?? []
        } else {
            tracks = decodedTracks
        }
        widthMin = container.map { decodeClamped($0, "widthMin", default: 0.01, 0.001, 1) } ?? 0.01
        widthMax = Swift.max(widthMin, container.map { decodeClamped($0, "widthMax", default: 0.08, 0.001, 1) } ?? 0.08)
        colors = decodeColors(container)
        let colorMode = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("colorMode"))) ?? nil) ?? "cycle"
        randomColors = colorMode == "random"
        let capRaw = ((try? container?.decodeIfPresent(String.self, forKey: OrbCodingKey("cap"))) ?? nil) ?? "round"
        cap = OrbStrokeCap(rawValue: capRaw) ?? .round
        idleLengthMin = container.map { decodeClamped($0, "idleLengthMin", default: 0.05, 0, 1) } ?? 0.05
        idleLengthMax = Swift.max(idleLengthMin, container.map { decodeClamped($0, "idleLengthMax", default: 0.15, 0, 1) } ?? 0.15)
        loadLength = container.map { decodeClamped($0, "loadLength", default: 0.9, 0, 1) } ?? 0.9
        speedMin = container.map { decodeClamped($0, "speedMin", default: 0.1, 0, 4) } ?? 0.1
        speedMax = container.map { decodeClamped($0, "speedMax", default: 0.3, 0, 4) } ?? 0.3
        loadSpeed = container.map { decodeClamped($0, "loadSpeed", default: 0.4, 0, 4) } ?? 0.4
        lengthEase = container.map { decodeClamped($0, "lengthEase", default: 1, 0.01, 30) } ?? 1
        velocityEase = container.map { decodeClamped($0, "velocityEase", default: 1, 0.01, 30) } ?? 1
        resampleMin = container.map { decodeClamped($0, "resampleMin", default: 0.8, 0.05, 60) } ?? 0.8
        resampleJitter = container.map { decodeClamped($0, "resampleJitter", default: 0.6, 0, 60) } ?? 0.6
    }
}

// MARK: - Layer + module documents

enum OrbLayer: Equatable {
    case disc(OrbDiscLayer)
    case ring(OrbRingLayer)
    case arc(OrbArcLayer)
    case arcField(OrbArcFieldLayer)
    case line(OrbLineLayer)
    case polygon(OrbPolygonLayer)
    case lineField(OrbLineFieldLayer)

    var base: OrbLayerBase {
        switch self {
        case .disc(let layer): return layer.base
        case .ring(let layer): return layer.base
        case .arc(let layer): return layer.base
        case .arcField(let layer): return layer.base
        case .line(let layer): return layer.base
        case .polygon(let layer): return layer.base
        case .lineField(let layer): return layer.base
        }
    }
}

/// Failable layer wrapper: unknown layer types decode to nil and are
/// dropped, so documents from a future (same-major) format degrade
/// gracefully instead of failing the whole module.
private struct OrbLayerDecoder: Decodable {
    let layer: OrbLayer?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: OrbCodingKey.self),
              let type = try? container.decode(String.self, forKey: OrbCodingKey("type"))
        else {
            layer = nil
            return
        }
        switch type {
        case "disc": layer = (try? OrbDiscLayer(from: decoder)).map(OrbLayer.disc)
        case "ring": layer = (try? OrbRingLayer(from: decoder)).map(OrbLayer.ring)
        case "arc": layer = (try? OrbArcLayer(from: decoder)).map(OrbLayer.arc)
        case "arcField": layer = (try? OrbArcFieldLayer(from: decoder)).map(OrbLayer.arcField)
        case "line": layer = (try? OrbLineLayer(from: decoder)).map(OrbLayer.line)
        case "polygon": layer = (try? OrbPolygonLayer(from: decoder)).map(OrbLayer.polygon)
        case "lineField": layer = (try? OrbLineFieldLayer(from: decoder)).map(OrbLayer.lineField)
        default: layer = nil
        }
    }
}

/// Current module format version; documents from a NEWER version are
/// rejected whole (the renderer cannot know what it would be missing).
let orbModuleFormatVersion = 1

struct OrbModuleSetting: Equatable, Decodable {
    var id: String
    var label: String
    var description: String?
    var min: Double
    var max: Double
    var step: Double
    var defaultValue: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OrbCodingKey.self)
        let rawID = (try? container.decode(String.self, forKey: OrbCodingKey("id"))) ?? ""
        guard isValidOrbModuleID(rawID) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid orb setting id"))
        }
        id = rawID
        let rawLabel = ((try? container.decodeIfPresent(String.self, forKey: OrbCodingKey("label"))) ?? nil) ?? rawID
        let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        label = String((trimmedLabel.isEmpty ? rawID : trimmedLabel).prefix(40))
        if let rawDescription = (try? container.decodeIfPresent(String.self, forKey: OrbCodingKey("description"))).flatMap({ $0 }) {
            let trimmed = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            description = trimmed.isEmpty ? nil : String(trimmed.prefix(140))
        } else {
            description = nil
        }
        let rawMin = (try? container.decodeIfPresent(Double.self, forKey: OrbCodingKey("min"))).flatMap { $0 } ?? 0
        let rawMax = (try? container.decodeIfPresent(Double.self, forKey: OrbCodingKey("max"))).flatMap { $0 } ?? Swift.max(rawMin, 100)
        min = rawMin.isFinite ? rawMin : 0
        max = rawMax.isFinite ? Swift.max(min, rawMax) : Swift.max(min, 100)
        let span = max - min
        step = clamped(
            (try? container.decodeIfPresent(Double.self, forKey: OrbCodingKey("step"))).flatMap { $0 } ?? 1,
            span > 0 ? 0.001 : 1,
            span > 0 ? span : 1
        )
        defaultValue = clamped(
            (try? container.decodeIfPresent(Double.self, forKey: OrbCodingKey("default"))).flatMap { $0 } ?? min,
            min,
            max
        )
    }
}

struct OrbModule: Equatable, Decodable {
    var id: String
    var name: String
    var description: String
    var alertPulsePeriod: Double
    var settings: [OrbModuleSetting]
    var layers: [OrbLayer]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OrbCodingKey.self)
        let rawID = (try? container.decode(String.self, forKey: OrbCodingKey("id"))) ?? ""
        guard isValidOrbModuleID(rawID) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid orb module id"))
        }
        let version = Int(decodeClamped(container, "formatVersion", default: Double(orbModuleFormatVersion), 0, 1000))
        guard version <= orbModuleFormatVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unsupported format version"))
        }
        id = rawID
        let rawName = ((try? container.decodeIfPresent(String.self, forKey: OrbCodingKey("name"))) ?? nil) ?? ""
        name = rawName.trimmingCharacters(in: .whitespaces).isEmpty ? rawID : rawName
        description = ((try? container.decodeIfPresent(String.self, forKey: OrbCodingKey("description"))) ?? nil) ?? ""
        alertPulsePeriod = decodeClamped(container, "alertPulsePeriod", default: 1.2, 0.05, 60)
        let decodedSettings = ((try? container.decodeIfPresent([OrbModuleSetting].self, forKey: OrbCodingKey("settings"))) ?? nil) ?? []
        settings = Dictionary(grouping: decodedSettings, by: \.id).compactMap { $0.value.first }
        let decoded = ((try? container.decodeIfPresent([OrbLayerDecoder].self, forKey: OrbCodingKey("layers"))) ?? nil) ?? []
        layers = decoded.compactMap(\.layer)
        guard !layers.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "module has no usable layers"))
        }
    }

    func resolvedSettings(saved: [String: Double]?) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: settings.map { declaration in
            let value = saved?[declaration.id] ?? declaration.defaultValue
            return (declaration.id, clamped(value, declaration.min, declaration.max))
        })
    }
}

/// Module ids are short url/file-safe slugs (mirrors the web validator).
func isValidOrbModuleID(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 64 else { return false }
    return value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil
}

/// `GET /api/orb-modules` response: a lossy list so one bad module on the
/// host never sinks the whole catalog.
struct OrbModulesResponse: Decodable {
    let modules: [OrbModule]

    private struct FailableModule: Decodable {
        let module: OrbModule?
        init(from decoder: Decoder) throws {
            module = try? OrbModule(from: decoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case modules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let failable = (try? container.decode([FailableModule].self, forKey: .modules)) ?? []
        modules = failable.compactMap(\.module)
    }
}

// MARK: - Palette

/// A concrete color: rgb channels (0-255) plus 0..1 alpha.
struct OrbResolvedColor {
    var rgb: ThemeRGB
    var alpha: Double

    var color: Color {
        rgb.color.opacity(alpha)
    }
}

/// Every theme slot resolved to a concrete color for the current frame.
/// Built once per frame from the shared avatar theme so theme edits flow
/// straight into module colors:
///   - line1..3 carry their per-line theme opacities as alpha,
///   - gymNumber carries its theme opacity,
///   - innerShadow is black at the theme's innerShadowOpacity.
struct OrbPalette {
    let avatar: DashboardAvatarTheme

    func resolved(_ slot: OrbThemeSlot) -> OrbResolvedColor {
        switch slot {
        case .gradientCenter:
            return OrbResolvedColor(rgb: avatar.gradientCenter, alpha: 1)
        case .gradientOuter:
            return OrbResolvedColor(rgb: avatar.gradientOuter, alpha: 1)
        case .gradientAlert:
            return OrbResolvedColor(rgb: avatar.gradientAlert, alpha: 1)
        case .line1:
            return lineColor(0)
        case .line2:
            return lineColor(1)
        case .line3:
            return lineColor(2)
        case .gymNumber:
            return OrbResolvedColor(rgb: avatar.gymNumberColor, alpha: avatar.gymNumberOpacity)
        case .innerShadow:
            return OrbResolvedColor(rgb: ThemeRGB(red: 0, green: 0, blue: 0), alpha: avatar.innerShadowOpacity)
        }
    }

    private func lineColor(_ index: Int) -> OrbResolvedColor {
        let rgb = index < avatar.lineColors.count ? avatar.lineColors[index] : ThemeRGB(red: 255, green: 255, blue: 255)
        let alpha = index < avatar.lineOpacities.count ? avatar.lineOpacities[index] : 1
        return OrbResolvedColor(rgb: rgb, alpha: clamped(alpha))
    }
}

/// Resolve a color ref against the palette. `alertPulse` is the 0..1 alert
/// oscillation (0 while inactive); refs carrying `alertTheme` mix toward
/// that slot by the pulse — how the classic background throbs to the alert
/// color with zero module-specific renderer code.
func resolveOrbColor(_ ref: OrbColorRef, palette: OrbPalette, alertPulse: Double) -> OrbResolvedColor {
    var base: OrbResolvedColor
    if let slot = ref.theme {
        base = palette.resolved(slot)
    } else {
        base = OrbResolvedColor(rgb: ref.hexRGB ?? ThemeRGB(red: 255, green: 255, blue: 255), alpha: 1)
    }
    if let alertSlot = ref.alertTheme, alertPulse > 0 {
        let alert = palette.resolved(alertSlot)
        base.rgb = base.rgb.mixed(with: alert.rgb, amount: alertPulse)
        base.alpha += (alert.alpha - base.alpha) * alertPulse
    }
    if let alpha = ref.alpha {
        base.alpha *= alpha
    }
    base.alpha = clamped(base.alpha)
    return base
}

// MARK: - Animation state

/// Per-segment state for one arcField layer. Angles/sweeps are in turns,
/// velocities in turns/second — identical to the web renderer's state.
struct OrbArcSegment {
    var colorIndex: Int
    var baseRadius: Double
    var width: Double
    var angle: Double
    var velocity: Double
    var targetVelocity: Double
    var sweep: Double
    var targetSweep: Double
    var nextResampleAt: TimeInterval
}

/// Per-segment state for one lineField layer. `position` is the segment's
/// center as a fraction of its track; velocities are track-lengths/second.
struct OrbLineSegment {
    var trackIndex: Int
    var colorIndex: Int
    var width: Double
    var position: Double
    var velocity: Double
    var targetVelocity: Double
    var length: Double
    var targetLength: Double
    var nextResampleAt: TimeInterval
}

private func assignColorIndex(_ index: Int, colorCount: Int, random: Bool) -> Int {
    guard colorCount > 0 else { return 0 }
    return random ? Int.random(in: 0..<colorCount) : index % colorCount
}

/// Holds the animated layers' segment state for one mounted orb. Rebuilt
/// whenever the module changes (restarting the animation, like the web
/// renderer); theme color edits never touch it because colors resolve from
/// the per-frame palette.
final class OrbAnimationModel: ObservableObject {
    private var module: OrbModule?
    private var arcStates: [Int: [OrbArcSegment]] = [:]
    private var lineStates: [Int: [OrbLineSegment]] = [:]
    private var lastTime: TimeInterval?
    private var fieldSegmentLimit: Int?

    /// Ensure state matches the module and advance the frame clock.
    /// Returns the clamped dt for this frame.
    func beginFrame(module: OrbModule, now: TimeInterval, fieldSegmentLimit: Int? = nil) -> Double {
        let normalizedLimit = fieldSegmentLimit.map { max(1, $0) }
        if self.module != module || self.fieldSegmentLimit != normalizedLimit {
            rebuild(module: module, fieldSegmentLimit: normalizedLimit)
        }
        let dt = min(0.05, max(0.001, now - (lastTime ?? now)))
        lastTime = now
        return dt
    }

    private func rebuild(module: OrbModule, fieldSegmentLimit: Int?) {
        self.module = module
        self.fieldSegmentLimit = fieldSegmentLimit
        arcStates = [:]
        lineStates = [:]
        lastTime = nil
        for (index, layer) in module.layers.enumerated() {
            switch layer {
            case .arcField(let field):
                arcStates[index] = Self.createArcSegments(
                    field,
                    count: min(field.count, fieldSegmentLimit ?? field.count)
                )
            case .lineField(let field):
                lineStates[index] = Self.createLineSegments(
                    field,
                    count: min(field.count, fieldSegmentLimit ?? field.count)
                )
            default:
                break
            }
        }
    }

    /// Initial arcField population: radii spread (or ring-snapped) across the
    /// band with jitter, zeroed motion targets, and an immediate resample so
    /// the first frame samples real targets — the web convention.
    private static func createArcSegments(_ layer: OrbArcFieldLayer, count: Int) -> [OrbArcSegment] {
        let ringCount = max(1, layer.ringCount)
        return (0..<count).map { index in
            let spreadT = count > 1 ? Double(index) / Double(count - 1) : 0.5
            let ringT = ringCount > 1 ? Double(index % ringCount) / Double(ringCount - 1) : 0.5
            let t = layer.ringsDistribution ? ringT : spreadT
            let jitter = (Double.random(in: 0...1) - 0.5) * layer.ringJitter
            let radius = clamped(layer.radiusMin + t * (layer.radiusMax - layer.radiusMin) + jitter, layer.radiusMin, layer.radiusMax)
            return OrbArcSegment(
                colorIndex: assignColorIndex(index, colorCount: layer.colors.count, random: layer.randomColors),
                baseRadius: radius,
                width: Double.random(in: layer.widthMin...max(layer.widthMin, layer.widthMax)),
                angle: Double.random(in: 0..<1),
                velocity: 0,
                targetVelocity: 0,
                sweep: 0,
                targetSweep: 0,
                nextResampleAt: 0
            )
        }
    }

    /// Initial lineField population: round-robin track assignment (two
    /// tracks split the swarm in half), random starting positions so
    /// co-track segments are desynced, zeroed motion targets.
    private static func createLineSegments(_ layer: OrbLineFieldLayer, count: Int) -> [OrbLineSegment] {
        (0..<count).map { index in
            OrbLineSegment(
                trackIndex: layer.tracks.isEmpty ? 0 : index % layer.tracks.count,
                colorIndex: assignColorIndex(index, colorCount: layer.colors.count, random: layer.randomColors),
                width: Double.random(in: layer.widthMin...max(layer.widthMin, layer.widthMax)),
                position: Double.random(in: 0...1),
                velocity: 0,
                targetVelocity: 0,
                length: 0,
                targetLength: 0,
                nextResampleAt: 0
            )
        }
    }

    /// Step and return one arcField layer's segments. Mirrors the web step:
    /// resample sweep/velocity targets on a randomized deadline (scaled by
    /// load), ease toward them, integrate the angle.
    func arcSegments(layerIndex: Int, layer: OrbArcFieldLayer, load: Double, now: TimeInterval, dt: Double) -> [OrbArcSegment] {
        guard var segments = arcStates[layerIndex] else { return [] }
        for index in segments.indices {
            if now >= segments[index].nextResampleAt {
                let idle = Double.random(in: layer.idleSweepMin...max(layer.idleSweepMin, layer.idleSweepMax))
                segments[index].targetSweep = idle + (layer.loadSweep - idle) * load
                let speed = Double.random(in: layer.speedMin...max(layer.speedMin, layer.speedMax)) + load * layer.loadSpeed
                segments[index].targetVelocity = (Bool.random() ? -1.0 : 1.0) * speed
                segments[index].nextResampleAt = now + layer.resampleMin + Double.random(in: 0...1) * layer.resampleJitter
            }
            segments[index].sweep += (segments[index].targetSweep - segments[index].sweep) * min(1, dt * layer.sweepEase)
            segments[index].velocity += (segments[index].targetVelocity - segments[index].velocity) * min(1, dt * layer.velocityEase)
            segments[index].angle += segments[index].velocity * dt
        }
        arcStates[layerIndex] = segments
        return segments
    }

    /// Step and return one lineField layer's segments: resample length and a
    /// randomly-directed velocity, ease toward both (all movement lerps),
    /// integrate the position, and bounce off the track ends keeping the
    /// whole segment inside [0, 1].
    func lineSegments(layerIndex: Int, layer: OrbLineFieldLayer, load: Double, now: TimeInterval, dt: Double) -> [OrbLineSegment] {
        guard var segments = lineStates[layerIndex] else { return [] }
        for index in segments.indices {
            if now >= segments[index].nextResampleAt {
                let idle = Double.random(in: layer.idleLengthMin...max(layer.idleLengthMin, layer.idleLengthMax))
                segments[index].targetLength = min(1, idle + (layer.loadLength - idle) * load)
                let speed = Double.random(in: layer.speedMin...max(layer.speedMin, layer.speedMax)) + load * layer.loadSpeed
                segments[index].targetVelocity = (Bool.random() ? -1.0 : 1.0) * speed
                segments[index].nextResampleAt = now + layer.resampleMin + Double.random(in: 0...1) * layer.resampleJitter
            }
            segments[index].length += (segments[index].targetLength - segments[index].length) * min(1, dt * layer.lengthEase)
            segments[index].velocity += (segments[index].targetVelocity - segments[index].velocity) * min(1, dt * layer.velocityEase)
            segments[index].position += segments[index].velocity * dt

            // Bounce: the segment spans [pos - len/2, pos + len/2] and must
            // stay inside the track. Hitting an end reflects both the live
            // and target velocity so the bounce doesn't fight the easing.
            let half = segments[index].length / 2
            let minPos = half
            let maxPos = 1 - half
            if minPos >= maxPos {
                segments[index].position = 0.5
            } else if segments[index].position > maxPos {
                segments[index].position = maxPos
                segments[index].velocity = -abs(segments[index].velocity)
                segments[index].targetVelocity = -abs(segments[index].targetVelocity)
            } else if segments[index].position < minPos {
                segments[index].position = minPos
                segments[index].velocity = abs(segments[index].velocity)
                segments[index].targetVelocity = abs(segments[index].targetVelocity)
            }
        }
        lineStates[layerIndex] = segments
        return segments
    }
}

// MARK: - Renderer

/// Everything the renderer needs for one frame.
struct OrbFrame {
    var center: CGPoint
    /// Orb radius in points (unit 1.0 in module space).
    var radius: Double
    var palette: OrbPalette
    var load: Double
    var alertActive: Bool
    var now: TimeInterval
    var dt: Double
}

/// Draw one frame of a status orb module into a SwiftUI GraphicsContext.
/// Layers render in document order, each isolated in its own transparency
/// layer with its blend mode, opacity (including pulse), optional clip to
/// the orb's unit disc, and glow (a shadow filter in the drawn color).
func drawOrbModule(
    _ context: GraphicsContext,
    module: OrbModule,
    model: OrbAnimationModel,
    frame: OrbFrame
) {
    // One shared alert oscillation per frame: 0 when inactive, otherwise a
    // raised-cosine 0..1 wave over the module's alertPulsePeriod. Drives both
    // alertTheme color mixing and alertOnly layer pulses.
    let alertPulse = frame.alertActive
        ? (1 - cos((frame.now / module.alertPulsePeriod) * .pi * 2)) / 2
        : 0

    for (index, layer) in module.layers.enumerated() {
        let base = layer.base
        if !base.enabled { continue }

        // Layer opacity = static opacity x pulse wave; alertOnly layers do
        // not render at all while the alert is inactive.
        var opacity = base.opacity
        if let pulse = base.pulse {
            if pulse.alertOnly && !frame.alertActive { continue }
            let wave = (1 - cos((frame.now / pulse.period) * .pi * 2)) / 2
            opacity *= pulse.min + (pulse.max - pulse.min) * wave
        }
        if opacity <= 0 { continue }

        context.drawLayer { layerContext in
            layerContext.blendMode = base.blend.graphicsBlendMode
            layerContext.opacity = opacity
            if base.clip {
                // Confine the layer to the orb interior so gradients and
                // glows cannot spill past the rim (the glass gloss stack
                // relies on this).
                layerContext.clip(to: Path(ellipseIn: orbRect(frame)))
            }

            switch layer {
            case .disc(let disc):
                drawDisc(layerContext, disc, frame: frame, alertPulse: alertPulse)
            case .ring(let ring):
                drawRing(layerContext, ring, frame: frame, alertPulse: alertPulse)
            case .arc(let arc):
                drawArc(layerContext, arc, frame: frame, alertPulse: alertPulse)
            case .arcField(let field):
                let segments = model.arcSegments(layerIndex: index, layer: field, load: frame.load, now: frame.now, dt: frame.dt)
                drawArcField(layerContext, field, segments: segments, frame: frame, alertPulse: alertPulse)
            case .line(let line):
                drawLine(layerContext, line, frame: frame, alertPulse: alertPulse)
            case .polygon(let polygon):
                drawPolygon(layerContext, polygon, frame: frame, alertPulse: alertPulse)
            case .lineField(let field):
                let segments = model.lineSegments(layerIndex: index, layer: field, load: frame.load, now: frame.now, dt: frame.dt)
                drawLineField(layerContext, field, segments: segments, frame: frame, alertPulse: alertPulse)
            }
        }
    }
}

private func orbRect(_ frame: OrbFrame) -> CGRect {
    CGRect(
        x: Double(frame.center.x) - frame.radius,
        y: Double(frame.center.y) - frame.radius,
        width: frame.radius * 2,
        height: frame.radius * 2
    )
}

/// Unit-space length to points.
private func px(_ frame: OrbFrame, _ value: Double) -> Double {
    value * frame.radius
}

/// Unit-space point to canvas points. Trig/match stays in Double end to end
/// (mixing into CGFloat invites Darwin/CoreGraphics cos ambiguity).
private func point(_ frame: OrbFrame, _ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: Double(frame.center.x) + x * frame.radius, y: Double(frame.center.y) + y * frame.radius)
}

private func gradientStops(_ stops: [OrbGradientStop], palette: OrbPalette, alertPulse: Double) -> Gradient {
    Gradient(stops: stops.map { stop in
        .init(color: resolveOrbColor(stop.color, palette: palette, alertPulse: alertPulse).color, location: stop.at)
    })
}

/// The strongest-alpha stop, used as the glow color for gradient shapes.
private func brightestStop(_ stops: [OrbGradientStop], palette: OrbPalette, alertPulse: Double) -> OrbResolvedColor {
    var best = resolveOrbColor(stops[0].color, palette: palette, alertPulse: alertPulse)
    for stop in stops.dropFirst() {
        let resolved = resolveOrbColor(stop.color, palette: palette, alertPulse: alertPulse)
        if resolved.alpha > best.alpha {
            best = resolved
        }
    }
    return best
}

private func drawDisc(_ context: GraphicsContext, _ layer: OrbDiscLayer, frame: OrbFrame, alertPulse: Double) {
    var context = context
    let center = point(frame, layer.center.x, layer.center.y)
    let rx = px(frame, layer.radius)
    let ry = rx * layer.scaleY
    var path = Path(ellipseIn: CGRect(
        x: Double(center.x) - rx,
        y: Double(center.y) - ry,
        width: rx * 2,
        height: ry * 2
    ))
    if layer.rotation != 0 {
        // Rotate only the PATH about the disc center; the gradient stays in
        // unrotated unit space, matching the web renderer exactly.
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: layer.rotation * .pi * 2)
            .translatedBy(x: -center.x, y: -center.y)
        path = path.applying(transform)
    }

    if layer.base.glow > 0 {
        let glowColor = brightestStop(layer.stops, palette: frame.palette, alertPulse: alertPulse)
        context.addFilter(.shadow(color: glowColor.color, radius: px(frame, layer.base.glow)))
    }

    if layer.stops.count == 1 {
        // Single stop: plain solid fill.
        let color = resolveOrbColor(layer.stops[0].color, palette: frame.palette, alertPulse: alertPulse)
        context.fill(path, with: .color(color.color))
        return
    }

    // Radial gradient between the module's focus circles. GraphicsContext
    // radial gradients are concentric, so offset focal gradients (vignettes)
    // are approximated at the from-circle's center — the same approximation
    // the original hand-coded tvOS orb used, visually indistinguishable at
    // orb sizes.
    let from = layer.gradientFrom ?? defaultGradientCircle(layer.center, radius: 0)
    let to = layer.gradientTo ?? defaultGradientCircle(layer.center, radius: layer.radius)
    context.fill(
        path,
        with: .radialGradient(
            gradientStops(layer.stops, palette: frame.palette, alertPulse: alertPulse),
            center: point(frame, from.x, from.y),
            startRadius: px(frame, from.radius),
            endRadius: px(frame, to.radius)
        )
    )
}

/// Default gradient circles trace a plain center-out gradient when the
/// module omits explicit focus circles. (Built outside Decodable because
/// OrbGradientCircle only initializes from JSON.)
private func defaultGradientCircle(_ center: OrbPoint, radius: Double) -> OrbGradientCircle {
    let json = #"{"x": \#(center.x), "y": \#(center.y), "radius": \#(radius)}"#
    // Literal JSON from numeric interpolation cannot fail to decode.
    return try! JSONDecoder().decode(OrbGradientCircle.self, from: Data(json.utf8))
}

private func drawRing(_ context: GraphicsContext, _ layer: OrbRingLayer, frame: OrbFrame, alertPulse: Double) {
    var context = context
    let color = resolveOrbColor(layer.color, palette: frame.palette, alertPulse: alertPulse)
    let r = px(frame, layer.radius)
    let rect = CGRect(
        x: Double(frame.center.x) - r,
        y: Double(frame.center.y) - r,
        width: r * 2,
        height: r * 2
    )
    if layer.base.glow > 0 {
        context.addFilter(.shadow(color: color.color, radius: px(frame, layer.base.glow)))
    }
    context.stroke(Path(ellipseIn: rect), with: .color(color.color), lineWidth: px(frame, layer.width))
}

private func drawArc(_ context: GraphicsContext, _ layer: OrbArcLayer, frame: OrbFrame, alertPulse: Double) {
    var context = context
    let startRad = layer.from * .pi * 2
    let endRad = layer.to * .pi * 2
    var path = Path()
    path.addArc(
        center: frame.center,
        radius: px(frame, layer.radius),
        startAngle: .radians(startRad),
        endAngle: .radians(endRad),
        clockwise: false
    )

    // Gradient runs along the chord between the arc's endpoints (at the
    // stroke radius), reversed when requested, so brightness tapers along
    // the sweep.
    let a = point(frame, cos(startRad) * layer.radius, sin(startRad) * layer.radius)
    let b = point(frame, cos(endRad) * layer.radius, sin(endRad) * layer.radius)
    let gradient = gradientStops(layer.stops, palette: frame.palette, alertPulse: alertPulse)

    if layer.base.glow > 0 {
        let glowColor = brightestStop(layer.stops, palette: frame.palette, alertPulse: alertPulse)
        context.addFilter(.shadow(color: glowColor.color, radius: px(frame, layer.base.glow)))
    }
    context.stroke(
        path,
        with: .linearGradient(gradient, startPoint: layer.reverse ? b : a, endPoint: layer.reverse ? a : b),
        style: StrokeStyle(lineWidth: px(frame, layer.width), lineCap: layer.cap.lineCap)
    )
}

private func drawArcField(
    _ context: GraphicsContext,
    _ layer: OrbArcFieldLayer,
    segments: [OrbArcSegment],
    frame: OrbFrame,
    alertPulse: Double
) {
    for segment in segments {
        guard segment.colorIndex < layer.colors.count else { continue }
        let color = resolveOrbColor(layer.colors[segment.colorIndex], palette: frame.palette, alertPulse: alertPulse)
        let startRad = segment.angle * .pi * 2
        let endRad = startRad + segment.sweep * .pi * 2
        var path = Path()
        path.addArc(
            center: frame.center,
            radius: px(frame, segment.baseRadius),
            startAngle: .radians(startRad),
            endAngle: .radians(endRad),
            clockwise: false
        )
        // Each segment glows in its own color inside its own layer, matching
        // both the web renderer and the original hand-coded tvOS arcs.
        context.drawLayer { segmentContext in
            var segmentContext = segmentContext
            if layer.base.glow > 0 {
                segmentContext.addFilter(.shadow(color: color.color, radius: px(frame, layer.base.glow)))
            }
            segmentContext.stroke(
                path,
                with: .color(color.color),
                style: StrokeStyle(lineWidth: px(frame, segment.width), lineCap: layer.cap.lineCap)
            )
        }
    }
}

private func drawLine(_ context: GraphicsContext, _ layer: OrbLineLayer, frame: OrbFrame, alertPulse: Double) {
    var context = context
    let color = resolveOrbColor(layer.color, palette: frame.palette, alertPulse: alertPulse)
    var path = Path()
    path.move(to: point(frame, layer.from.x, layer.from.y))
    path.addLine(to: point(frame, layer.to.x, layer.to.y))
    if layer.base.glow > 0 {
        context.addFilter(.shadow(color: color.color, radius: px(frame, layer.base.glow)))
    }
    context.stroke(
        path,
        with: .color(color.color),
        style: StrokeStyle(lineWidth: px(frame, layer.width), lineCap: layer.cap.lineCap)
    )
}

private func drawPolygon(_ context: GraphicsContext, _ layer: OrbPolygonLayer, frame: OrbFrame, alertPulse: Double) {
    var context = context
    guard let first = layer.points.first else { return }
    let color = resolveOrbColor(layer.color, palette: frame.palette, alertPulse: alertPulse)
    var path = Path()
    path.move(to: point(frame, first.x, first.y))
    for vertex in layer.points.dropFirst() {
        path.addLine(to: point(frame, vertex.x, vertex.y))
    }
    if layer.close {
        path.closeSubpath()
    }
    if layer.base.glow > 0 {
        context.addFilter(.shadow(color: color.color, radius: px(frame, layer.base.glow)))
    }
    if layer.fill {
        context.fill(path, with: .color(color.color))
    } else {
        context.stroke(path, with: .color(color.color), lineWidth: px(frame, layer.width))
    }
}

private func drawLineField(
    _ context: GraphicsContext,
    _ layer: OrbLineFieldLayer,
    segments: [OrbLineSegment],
    frame: OrbFrame,
    alertPulse: Double
) {
    for segment in segments {
        guard segment.trackIndex < layer.tracks.count, segment.colorIndex < layer.colors.count else { continue }
        let track = layer.tracks[segment.trackIndex]
        // Convert the segment's [pos - len/2, pos + len/2] track span into
        // endpoints by lerping along its track.
        let t0 = segment.position - segment.length / 2
        let t1 = segment.position + segment.length / 2
        let a = point(
            frame,
            track.from.x + (track.to.x - track.from.x) * t0,
            track.from.y + (track.to.y - track.from.y) * t0
        )
        let b = point(
            frame,
            track.from.x + (track.to.x - track.from.x) * t1,
            track.from.y + (track.to.y - track.from.y) * t1
        )
        let color = resolveOrbColor(layer.colors[segment.colorIndex], palette: frame.palette, alertPulse: alertPulse)
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        context.drawLayer { segmentContext in
            var segmentContext = segmentContext
            if layer.base.glow > 0 {
                segmentContext.addFilter(.shadow(color: color.color, radius: px(frame, layer.base.glow)))
            }
            segmentContext.stroke(
                path,
                with: .color(color.color),
                style: StrokeStyle(lineWidth: px(frame, segment.width), lineCap: layer.cap.lineCap)
            )
        }
    }
}
