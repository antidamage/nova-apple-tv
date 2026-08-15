import Foundation

// Status orb info modules on tvOS.
//
// This is a port of the web dashboard's `lib/orb-info/` — the same module
// contract, the same display config, and the same formatter. Both sides run the
// shared conformance table at `nova-ha-dashboard/lib/orb-info/format-cases.json`
// (see OrbInfoFormatTests), so the orb cannot read one way on the dashboard and
// another on the Apple TV.
//
// Modules whose data source does not exist on tvOS (the power readings, which
// come from the dashboard host's /api/power) deliberately report `unavailable`
// and render the empty glyph rather than inventing a number.

// MARK: - Contract

enum OrbBaseUnit: String, Decodable {
    case hours, count, ratio, percent, celsius, watts, timestamp, none
}

enum OrbInfoFormat: String, Decodable {
    case number, duration, percent, clock, temperature, text
}

enum OrbDisplayUnit: String, Decodable {
    case native, auto, seconds, minutes, hours, days, weeks
    case celsius, fahrenheit, watts, kilowatts
}

enum OrbRounding: String, Decodable {
    case floor, round, ceil
}

enum OrbPercentBasis: Equatable {
    case moduleThreshold
    case fixed(Double)
}

struct OrbInfoDisplay: Equatable {
    var format: OrbInfoFormat = .number
    var unit: OrbDisplayUnit = .native
    var decimals: Int = 0
    var rounding: OrbRounding = .floor
    var percentOf: OrbPercentBasis = .moduleThreshold
    var percentClamp: Bool = true
    var percentInvert: Bool = false
    var showUnit: Bool = false
    var signed: Bool = false
    var clock12Hour: Bool = false
    var clockSeconds: Bool = false
    var prefix: String = ""
    var suffix: String = ""
    var emptyText: String = "—"

    static let `default` = OrbInfoDisplay()
}

struct OrbModuleOutput {
    var value: Double?
    var text: String?
    var baseUnit: OrbBaseUnit = .none
    var observedAt: String?
    var status: Status = .unavailable
    var alert: Bool = false
    var alertThreshold: Double?
    var detail: String?

    enum Status: String {
        case ok, stale, unavailable, error
    }

    static let empty = OrbModuleOutput()
}

struct OrbFormatResult {
    let text: String
    let alert: Bool
    let accessibilityLabel: String
}

// MARK: - Lenient decoding of the shared payload

/// The `orbInfo` block off the dashboard state payload. Decoded leniently so an
/// older or newer dashboard never breaks the orb: anything unrecognised falls
/// back to the module's default display.
struct OrbInfoPayload: Decodable {
    var moduleID: String?
    var modules: [String: OrbModulePayload]?

    enum CodingKeys: String, CodingKey {
        case moduleID = "moduleId"
        case modules
    }
}

struct OrbModulePayload: Decodable {
    var display: OrbInfoDisplayPayload?
    var params: [String: OrbParamValue]?
}

/// A module parameter value: which zone, which sensor, which date, or a number.
/// Decoded leniently — the web side stores strings and numbers, and neither
/// side should break on the other's choice.
enum OrbParamValue: Decodable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        self = .string((try? container.decode(String.self)) ?? "")
    }
}

struct OrbInfoDisplayPayload: Decodable {
    var format: String?
    var unit: String?
    var decimals: Double?
    var rounding: String?
    var percentOf: PercentBasisPayload?
    var percentClamp: Bool?
    var percentInvert: Bool?
    var showUnit: Bool?
    var signed: Bool?
    var clock12Hour: Bool?
    var clockSeconds: Bool?
    var prefix: String?
    var suffix: String?
    var emptyText: String?

    struct PercentBasisPayload: Decodable {
        var kind: String?
        var value: Double?
    }

    /// Overlay the saved edits onto a base display (the module's default).
    func resolved(onto base: OrbInfoDisplay) -> OrbInfoDisplay {
        var display = base
        if let format, let parsed = OrbInfoFormat(rawValue: format) { display.format = parsed }
        if let unit, let parsed = OrbDisplayUnit(rawValue: unit) { display.unit = parsed }
        if let decimals, decimals.isFinite { display.decimals = min(3, max(0, Int(decimals.rounded()))) }
        if let rounding, let parsed = OrbRounding(rawValue: rounding) { display.rounding = parsed }
        if let percentOf {
            if percentOf.kind == "fixed", let value = percentOf.value, value.isFinite, value > 0 {
                display.percentOf = .fixed(value)
            } else if percentOf.kind == "moduleThreshold" {
                display.percentOf = .moduleThreshold
            }
        }
        if let percentClamp { display.percentClamp = percentClamp }
        if let percentInvert { display.percentInvert = percentInvert }
        if let showUnit { display.showUnit = showUnit }
        if let signed { display.signed = signed }
        if let clock12Hour { display.clock12Hour = clock12Hour }
        if let clockSeconds { display.clockSeconds = clockSeconds }
        if let prefix { display.prefix = String(prefix.prefix(8)) }
        if let suffix { display.suffix = String(suffix.prefix(8)) }
        if let emptyText { display.emptyText = String(emptyText.prefix(8)) }
        return display
    }
}

// MARK: - The formatter (port of lib/orb-info/format.ts)

private let secondsPerMinute: Double = 60
private let secondsPerHour: Double = 3600
private let secondsPerDay: Double = 86_400
private let secondsPerWeek: Double = 604_800

private func secondsPerBaseUnit(_ unit: OrbBaseUnit) -> Double? {
    unit == .hours ? secondsPerHour : nil
}

private func secondsPerDisplayUnit(_ unit: OrbDisplayUnit) -> Double {
    switch unit {
    case .seconds: return 1
    case .minutes: return secondsPerMinute
    case .days: return secondsPerDay
    case .weeks: return secondsPerWeek
    default: return secondsPerHour
    }
}

private func autoDurationUnit(_ totalSeconds: Double) -> OrbDisplayUnit {
    let magnitude = abs(totalSeconds)
    if magnitude < secondsPerMinute { return .seconds }
    if magnitude < secondsPerHour { return .minutes }
    if magnitude < secondsPerDay * 2 { return .hours }
    if magnitude < secondsPerWeek * 2 { return .days }
    return .weeks
}

private func unitSymbol(_ unit: OrbDisplayUnit) -> String {
    switch unit {
    case .seconds: return "s"
    case .minutes: return "m"
    case .hours: return "h"
    case .days: return "d"
    case .weeks: return "w"
    case .celsius: return "°C"
    case .fahrenheit: return "°F"
    case .watts: return "W"
    case .kilowatts: return "kW"
    default: return ""
    }
}

private func applyRounding(_ value: Double, decimals: Int, rounding: OrbRounding) -> Double {
    let scale = pow(10.0, Double(decimals))
    let scaled = value * scale
    // Match the JS nudge so 4.999999999 floors to 5 on both surfaces.
    let corrected = abs(scaled - scaled.rounded()) < 1e-9 ? scaled.rounded() : scaled
    switch rounding {
    case .ceil: return corrected.rounded(.up) / scale
    case .round: return corrected.rounded(.toNearestOrAwayFromZero) / scale
    case .floor: return corrected.rounded(.down) / scale
    }
}

private func renderNumber(_ value: Double, _ display: OrbInfoDisplay) -> String {
    let rounded = applyRounding(value, decimals: display.decimals, rounding: display.rounding)
    let safe = rounded == 0 ? 0 : rounded
    let body = String(format: "%.\(display.decimals)f", safe)
    return display.signed && safe > 0 ? "+\(body)" : body
}

private func clockText(_ epochMs: Double, _ display: OrbInfoDisplay) -> String {
    let date = Date(timeIntervalSince1970: epochMs / 1000)
    let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    var hour = parts.hour ?? 0
    if display.clock12Hour {
        hour = hour % 12
        if hour == 0 { hour = 12 }
    }
    let hourText = display.clock12Hour ? String(hour) : String(format: "%02d", hour)
    var text = "\(hourText):" + String(format: "%02d", parts.minute ?? 0)
    if display.clockSeconds { text += ":" + String(format: "%02d", parts.second ?? 0) }
    return text
}

private func convert(_ output: OrbModuleOutput, _ display: OrbInfoDisplay) -> (value: Double, unit: OrbDisplayUnit)? {
    guard let value = output.value, value.isFinite else { return nil }

    switch display.format {
    case .duration:
        guard let perBase = secondsPerBaseUnit(output.baseUnit) else { return (value, .native) }
        let totalSeconds = value * perBase
        let unit = (display.unit == .auto || display.unit == .native)
            ? autoDurationUnit(totalSeconds)
            : display.unit
        return (totalSeconds / secondsPerDisplayUnit(unit), unit)

    case .percent:
        if output.baseUnit == .percent { return (value, .native) }
        if output.baseUnit == .ratio { return (value * 100, .native) }
        let basis: Double?
        switch display.percentOf {
        case .fixed(let fixed): basis = fixed
        case .moduleThreshold: basis = output.alertThreshold
        }
        guard let basis, basis.isFinite, basis != 0 else { return nil }
        return ((value / basis) * 100, .native)

    case .temperature:
        if display.unit == .fahrenheit { return (value * 1.8 + 32, .fahrenheit) }
        return (value, .celsius)

    default:
        if output.baseUnit == .watts && display.unit == .kilowatts { return (value / 1000, .kilowatts) }
        if output.baseUnit == .watts { return (value, .watts) }
        return (value, display.unit == .auto ? .native : display.unit)
    }
}

func formatOrbValue(
    _ output: OrbModuleOutput,
    _ display: OrbInfoDisplay,
    label: String = "Status"
) -> OrbFormatResult {
    let empty = display.emptyText

    if display.format == .text {
        let text = output.status == .error ? empty : (output.text ?? empty)
        let spoken = output.text ?? "no reading"
        return OrbFormatResult(
            text: text,
            alert: output.alert,
            accessibilityLabel: "\(label): \(spoken)." + (output.detail.map { " \($0)" } ?? "")
        )
    }

    if output.status == .unavailable || output.status == .error || output.value == nil {
        return OrbFormatResult(
            text: empty,
            // An absent reading is not an alert; the orb must not pulse because
            // a scrape has not landed yet.
            alert: false,
            accessibilityLabel: "\(label): no reading." + (output.detail.map { " \($0)" } ?? "")
        )
    }

    if display.format == .clock, let value = output.value {
        let body = clockText(value, display)
        return OrbFormatResult(
            text: "\(display.prefix)\(body)\(display.suffix)",
            alert: output.alert,
            accessibilityLabel: "\(label): \(body)."
        )
    }

    guard let converted = convert(output, display) else {
        return OrbFormatResult(text: empty, alert: false, accessibilityLabel: "\(label): no reading.")
    }

    var numeric = converted.value
    var alert = output.alert

    if display.format == .percent {
        if display.percentInvert {
            numeric = 100 - numeric
            alert = output.alert || numeric <= 0
        }
        if display.percentClamp {
            numeric = min(100, max(0, numeric))
        }
    }

    let body = renderNumber(numeric, display)
    let symbol = display.showUnit
        ? (display.format == .percent ? "%" : unitSymbol(converted.unit))
        : ""
    let spoken = symbol.isEmpty && display.format == .percent ? "\(body) percent" : "\(body)\(symbol)"

    return OrbFormatResult(
        text: "\(display.prefix)\(body)\(symbol)\(display.suffix)",
        alert: alert,
        accessibilityLabel: "\(label): \(spoken)." + (output.detail.map { " \($0)" } ?? "")
    )
}
