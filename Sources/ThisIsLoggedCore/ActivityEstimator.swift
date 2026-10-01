import Foundation

/// Independent measurements: never contain Jira hours or the daily reporting target.
public struct ActivityFeatures: Codable, Equatable, Sendable {
  public let activeMinutes: Double
  public let promptCount: Int

  public init(activeMinutes: Double, promptCount: Int) {
    self.activeMinutes = activeMinutes
    self.promptCount = promptCount
  }
}

enum ActivityEstimator {
  static func features(events: [ActivityEvent], end: Date, fallbackIssue: String) -> [String: ActivityFeatures] {
    let prompts = events.filter { $0.kind == "UserPromptSubmit" }.sorted {
      $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt < $1.occurredAt
    }
    var result: [String: ActivityFeatures] = [:]
    for (index, prompt) in prompts.enumerated() {
      let issue = prompt.issueKey ?? fallbackIssue
      guard issue != ActivityStore.discardedIssue else { continue }
      let next = prompts.indices.contains(index + 1) ? prompts[index + 1].occurredAt : end
      let minutes = max(0, min(end, min(next, prompt.occurredAt.addingTimeInterval(1800))).timeIntervalSince(prompt.occurredAt) / 60)
      let previous = result[issue]
      result[issue] = ActivityFeatures(activeMinutes: (previous?.activeMinutes ?? 0) + minutes,
                                       promptCount: (previous?.promptCount ?? 0) + 1)
    }
    return result
  }

  static func analyze(
    events: [ActivityEvent], start: Date, end: Date, targetMinutes: Int?,
    reservedIntervals: [DateInterval], loggedSecondsByIssue: [String: Int],
    fallbackIssue: String, model: ActivityTimeModel?
  ) -> DailyActivity {
    let prompts = events.filter { $0.kind == "UserPromptSubmit" }
    let reserved = merged(reservedIntervals.compactMap { interval in
      let clippedStart = max(start, interval.start)
      let clippedEnd = min(end, interval.end)
      return clippedStart < clippedEnd ? DateInterval(start: clippedStart, end: clippedEnd) : nil
    })
    var seconds: [String: Double] = [:]
    for (index, prompt) in prompts.enumerated() {
      let nextPrompt = prompts.indices.contains(index + 1) ? prompts[index + 1].occurredAt : end
      let finish = min(nextPrompt, prompt.occurredAt.addingTimeInterval(1800))
      let interval = DateInterval(start: prompt.occurredAt, end: max(prompt.occurredAt, finish))
      let occupied = reserved.reduce(0) { total, meeting in
        total + max(0, min(interval.end, meeting.end).timeIntervalSince(max(interval.start, meeting.start)))
      }
      let issue = prompt.issueKey ?? fallbackIssue
      if issue != ActivityStore.discardedIssue { seconds[issue, default: 0] += max(0, interval.duration - occupied) }
    }
    var learned = false
    // Calendar-backed days retain the calendar-aware rules: the model is validated without meetings.
    if let model, reserved.isEmpty {
      for (issue, feature) in features(events: events, end: end, fallbackIssue: fallbackIssue)
        where issue != fallbackIssue && issue != "Nieprzypisane" {
        seconds[issue] = model.predict(feature) * 60
        learned = true
      }
    }
    let loggedUnits = loggedSecondsByIssue.reduce(into: [String: Int]()) { result, item in
      let value = Int((Double(max(0, item.value)) / 300).rounded())
      if value > 0 { result[item.key] = value }
    }
    let residualSeconds = seconds.reduce(into: [String: Double]()) { result, item in
      let value = max(0, item.value - Double(loggedUnits[item.key, default: 0] * 300))
      if value > 0 { result[item.key] = value }
    }
    let trackedSeconds = residualSeconds.values.reduce(0, +)
    let observedTaskUnits = trackedSeconds > 0 ? max(1, Int((trackedSeconds / 300).rounded())) : 0
    let reservedUnits = Int((reserved.reduce(0) { $0 + $1.duration } / 300).rounded())
    let uncoveredReservedUnits = max(0, reservedUnits - loggedUnits[fallbackIssue, default: 0])
    var units = loggedUnits
    if uncoveredReservedUnits > 0 { units[fallbackIssue, default: 0] += uncoveredReservedUnits }
    let fixedUnits = units.values.reduce(0, +)
    let requestedUnits = targetMinutes.map { Int((Double(max(0, $0)) / 5).rounded()) } ?? fixedUnits + observedTaskUnits
    let canInfer = !learned && seconds.keys.contains { $0 != "Nieprzypisane" }
    let trackedTaskUnits = canInfer ? max(observedTaskUnits, max(0, requestedUnits - fixedUnits)) : observedTaskUnits
    let distributionSeconds = trackedSeconds > 0 ? residualSeconds : seconds
    let distributionTotal = distributionSeconds.values.reduce(0, +)
    if trackedTaskUnits > 0, distributionTotal > 0 {
      let shares = distributionSeconds.map { (key: $0.key, exact: $0.value / distributionTotal * Double(trackedTaskUnits)) }
      var allocated = 0
      for share in shares {
        let value = Int(floor(share.exact))
        units[share.key, default: 0] += value
        allocated += value
      }
      var left = trackedTaskUnits - allocated
      for share in shares.sorted(by: {
        let a = $0.exact - floor($0.exact), b = $1.exact - floor($1.exact)
        return a == b ? $0.key < $1.key : a > b
      }) where left > 0 {
        units[share.key, default: 0] += 1
        left -= 1
      }
    }
    let allocations = units.filter { $0.value > 0 }.map { key, value in
      ActivityAllocation(issueKey: key, minutes: value * 5,
        evidence: prompts.filter { ($0.issueKey ?? fallbackIssue) == key }.count + (key == fallbackIssue ? reservedIntervals.count : 0),
        loggedMinutes: loggedUnits[key, default: 0] * 5)
    }.sorted { left, right in
      if left.issueKey == "Nieprzypisane" { return false }
      if right.issueKey == "Nieprzypisane" { return true }
      return left.minutes == right.minutes ? left.issueKey < right.issueKey : left.minutes > right.minutes
    }
    return DailyActivity(day: LocalDay(start).description,
      events: events.filter { $0.issueKey != ActivityStore.discardedIssue }, allocations: allocations,
      observedMinutes: (observedTaskUnits + uncoveredReservedUnits) * 5,
      inferredMinutes: max(0, trackedTaskUnits - observedTaskUnits) * 5,
      loggedMinutes: loggedUnits.values.reduce(0, +) * 5, usesLearnedEstimate: learned)
  }

  private static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
    let sorted = intervals.sorted { $0.start < $1.start }
    guard var current = sorted.first else { return [] }
    var result: [DateInterval] = []
    for interval in sorted.dropFirst() {
      if interval.start <= current.end {
        current = DateInterval(start: current.start, end: max(current.end, interval.end))
      } else {
        result.append(current)
        current = interval
      }
    }
    result.append(current)
    return result
  }
}
