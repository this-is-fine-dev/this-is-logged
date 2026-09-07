import EventKit
import Foundation

public struct CalendarSourceChoice: Equatable, Sendable {
  public let identifier: String
  public let title: String
}

public struct CalendarMeeting: Equatable, Sendable {
  public let title: String
  public let start: Date
  public let end: Date

  public var interval: DateInterval { DateInterval(start: start, end: end) }
}

public enum CalendarIntegrationError: LocalizedError {
  case accessDenied
  case calendarMissing

  public var errorDescription: String? {
    switch self {
    case .accessDenied: "Brak dostępu do Kalendarza macOS."
    case .calendarMissing: "Wybrane konto kalendarza nie jest już dostępne."
    }
  }
}

public enum CalendarIntegration {
  @MainActor public static func requestAccess() async throws -> Bool {
    let store = EKEventStore()
    if #available(macOS 14, *) { return try await store.requestFullAccessToEvents() }
    return try await store.requestAccess(to: .event)
  }

  @MainActor public static func sources() -> [CalendarSourceChoice] {
    guard hasAccess else { return [] }
    let calendars = EKEventStore().calendars(for: .event).filter { $0.type != .birthday }
    return Dictionary(grouping: calendars, by: { $0.source.sourceIdentifier }).values.compactMap { group in
      guard let source = group.first?.source else { return nil }
      let suffix = group.count == 1 ? "1 kalendarz" : "\(group.count) kalendarze"
      return CalendarSourceChoice(identifier: source.sourceIdentifier, title: "\(source.title) · \(suffix)")
    }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  @MainActor public static func sourceIdentifier(for selectionIdentifier: String) -> String? {
    guard hasAccess else { return nil }
    let store = EKEventStore()
    return store.sources.first(where: { $0.sourceIdentifier == selectionIdentifier })?.sourceIdentifier
      ?? store.calendar(withIdentifier: selectionIdentifier)?.source.sourceIdentifier
  }

  public static func workRange(on date: Date, now: Date, workdayHours: Double) -> DateInterval? {
    let calendar = Calendar.current
    let day = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    guard day <= today,
          let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day),
          let plannedEnd = calendar.date(byAdding: .minute, value: Int(workdayHours * 60), to: start) else { return nil }
    let end = day == today ? min(now, plannedEnd) : plannedEnd
    return start < end ? DateInterval(start: start, end: end) : nil
  }

  public static func meetings(calendarIdentifier: String, from: Date, to: Date) throws -> [CalendarMeeting] {
    guard hasAccess else { throw CalendarIntegrationError.accessDenied }
    let store = EKEventStore()
    let sourceIdentifier = store.sources.first(where: { $0.sourceIdentifier == calendarIdentifier })?.sourceIdentifier
      ?? store.calendar(withIdentifier: calendarIdentifier)?.source.sourceIdentifier
    let calendars = store.calendars(for: .event).filter {
      $0.source.sourceIdentifier == sourceIdentifier && $0.type != .birthday
    }
    guard !calendars.isEmpty else {
      throw CalendarIntegrationError.calendarMissing
    }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
    var seen: Set<String> = []
    return store.events(matching: predicate).compactMap { event in
      let response = event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus
      guard !event.isAllDay, event.status != .canceled,
            event.availability != .free, event.availability != .unavailable,
            response != .declined else { return nil }
      let start = max(from, event.startDate)
      let end = min(to, event.endDate)
      guard start < end else { return nil }
      let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let identity = "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(title)"
      guard seen.insert(identity).inserted else { return nil }
      return CalendarMeeting(
        title: title.isEmpty ? "Spotkanie bez tytułu" : title,
        start: start,
        end: end
      )
    }.sorted { $0.start < $1.start }
  }

  private static var hasAccess: Bool {
    let status = EKEventStore.authorizationStatus(for: .event)
    if #available(macOS 14, *) { return status == .fullAccess }
    return status == .authorized
  }
}
