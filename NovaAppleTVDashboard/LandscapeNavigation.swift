import Foundation

extension DashboardFocus {
    var accessibilityID: String {
        switch self {
        case .section(let id): return "section-" + id
        case .child(let id): return "child-" + id
        case .action(let zone, let action): return zone + "-" + action
        case .brightness(let id): return id + "-brightness"
        case .hue(let id): return id + "-hue"
        case .temperature(let zone, let id): return zone + "-" + id + "-temperature"
        case .fanSpeed(let zone, let id): return zone + "-" + id + "-fan"
        }
    }
}
