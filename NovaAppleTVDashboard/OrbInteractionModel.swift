import Foundation

func orbReminderEvent(moduleID: String, tasks: [TaskSummary]?, now: Date) -> OrbEventPayload? {
    guard ["next-reminder", "reminders-overdue"].contains(moduleID), let tasks else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let due = tasks.filter { task in
        if case .object(let wash)? = task.moduleData?["washing-machine"],
           wash["phase"]?.stringValue == "waiting" { return false }
        if let end = task.end {
            guard let date = parser.date(from: end) ?? ISO8601DateFormatter().date(from: end), date > now else { return false }
        }
        guard task.dismissedAt == nil,
              task.alertDismissedFor != task.start + ":" + (task.end ?? "reminder"),
              let start = parser.date(from: task.start) ?? ISO8601DateFormatter().date(from: task.start)
        else { return false }
        return start <= now
    }.sorted { $0.start > $1.start }.first
    guard let due else { return OrbEventPayload(alert: false) }
    let date = parser.date(from: due.start) ?? ISO8601DateFormatter().date(from: due.start)
    return OrbEventPayload(icon: "bell", alert: true, dismiss: OrbDismissPayload(kind: "reminder", id: due.id),
                           alertAt: date.map { $0.timeIntervalSince1970 * 1000 })
}
