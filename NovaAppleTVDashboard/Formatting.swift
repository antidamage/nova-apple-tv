import Foundation

// Display formatters shared across the dashboard views. These are presentation
// helpers only — they format optional numbers into the dashboard's compact,
// monospaced readout style and never carry control logic.

/// Temperature with a trailing `C`, dropping the decimal when whole; `--.-C`
/// when absent.
func temperatureText(_ value: Double?) -> String {
    guard let value else { return "--.-C" }
    if value.rounded() == value {
        return "\(Int(value))C"
    }
    return String(format: "%.1fC", value)
}

/// Bare temperature number (no unit) for the large climate readouts; `--.-` when
/// absent. The degree glyph is drawn separately so it can be sized independently.
func climateTemperatureDisplay(_ value: Double?) -> String {
    guard let value else { return "--.-" }
    if value.rounded() == value {
        return "\(Int(value))"
    }
    return String(format: "%.1f", value)
}

/// Rounded percentage; `--%` when absent.
func percentText(_ value: Double?) -> String {
    guard let value else { return "--%" }
    return "\(Int(value.rounded()))%"
}

/// Fixed-precision number; `--` when absent.
func numberText(_ value: Double?, digits: Int = 0) -> String {
    guard let value else { return "--" }
    return String(format: "%.\(digits)f", value)
}

/// Wind speed with its unit (e.g. `12 km/h`); `--` when absent.
func windText(_ weather: WeatherStatus) -> String {
    guard let wind = weather.windSpeed else { return "--" }
    return "\(Int(wind.rounded())) \(weather.windUnit ?? "")".trimmingCharacters(in: .whitespaces)
}

private func dashboardTimeFormatter(timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en")
    formatter.timeZone = timeZone
    formatter.dateFormat = "h:mm:ss a"
    return formatter
}

private let localDashboardTimeFormatter = dashboardTimeFormatter(timeZone: .autoupdatingCurrent)

private func dashboardMonthYearFormatter(timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMMM yyyy"
    return formatter
}

private let localDashboardMonthYearFormatter =
    dashboardMonthYearFormatter(timeZone: .autoupdatingCurrent)

private func dashboardCalendar(timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en")
    calendar.timeZone = timeZone
    return calendar
}

/// 12-hour local clock with seconds and uppercase AM/PM, matching the web.
func timeText(_ date: Date, timeZone: TimeZone? = nil) -> String {
    let formatter = timeZone.map { dashboardTimeFormatter(timeZone: $0) }
        ?? localDashboardTimeFormatter
    return formatter.string(from: date).uppercased()
}

func ordinalDay(_ day: Int) -> String {
    let remainder = day % 100
    if remainder >= 11 && remainder <= 13 {
        return "\(day)th"
    }
    switch day % 10 {
    case 1: return "\(day)st"
    case 2: return "\(day)nd"
    case 3: return "\(day)rd"
    default: return "\(day)th"
    }
}

/// Long local date, e.g. `27th July 2026`.
func dashboardDateText(_ date: Date, timeZone: TimeZone? = nil) -> String {
    let zone = timeZone ?? .autoupdatingCurrent
    let day = dashboardCalendar(timeZone: zone).component(.day, from: date)
    let formatter = timeZone.map { dashboardMonthYearFormatter(timeZone: $0) }
        ?? localDashboardMonthYearFormatter
    return "\(ordinalDay(day)) \(formatter.string(from: date))"
}

/// Monday-first weekday index used by the seven-day clock strip.
func dashboardWeekdayIndex(_ date: Date, timeZone: TimeZone? = nil) -> Int {
    let calendarIndex = dashboardCalendar(timeZone: timeZone ?? .autoupdatingCurrent)
        .component(.weekday, from: date)
    return (calendarIndex + 5) % 7
}

/// Human-readable location chip derived from the Apple TV's configured zone.
func dashboardLocationText(timeZone: TimeZone = .autoupdatingCurrent) -> String {
    let component = timeZone.identifier.split(separator: "/").last.map(String.init)
    let location = component?.replacingOccurrences(of: "_", with: " ")
    return (location?.isEmpty == false ? location : timeZone.abbreviation())?
        .uppercased() ?? "LOCAL"
}
