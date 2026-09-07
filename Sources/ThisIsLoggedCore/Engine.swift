import Foundation

public struct ReportSnapshot: Codable, Equatable, Sendable {
  public var backend: String?
  public var checkedAt: String
  public var lastSuccessfulAt: String?
  public var syncEnabled: Bool
  public var seconds: Int?
  public var expectedSeconds: Int
  public var error: String?
  public var targetError: String?
  public var today: PeriodReport?
  public var yesterday: PeriodReport?
  public var week: PeriodReport?
  public var month: PeriodReport?
  public var underreported: [LocalDay]?
  public var monthCapacity: MonthCapacity?

  public init(
    checkedAt: String,
    backend: String? = "swift",
    lastSuccessfulAt: String? = nil,
    syncEnabled: Bool,
    seconds: Int? = nil,
    expectedSeconds: Int,
    error: String? = nil,
    targetError: String? = nil,
    today: PeriodReport? = nil,
    yesterday: PeriodReport? = nil,
    week: PeriodReport? = nil,
    month: PeriodReport? = nil,
    underreported: [LocalDay]? = nil,
    monthCapacity: MonthCapacity? = nil
  ) {
    self.backend = backend
    self.checkedAt = checkedAt
    self.lastSuccessfulAt = lastSuccessfulAt
    self.syncEnabled = syncEnabled
    self.seconds = seconds
    self.expectedSeconds = expectedSeconds
    self.error = error
    self.targetError = targetError
    self.today = today
    self.yesterday = yesterday
    self.week = week
    self.month = month
    self.underreported = underreported
    self.monthCapacity = monthCapacity
  }
}

public struct ReminderDecision: Equatable, Sendable {
  public let missingDays: [MissingDay]
  public let message: String?
}

public enum SyncState: String, Codable, Sendable { case add, synced, collision }
public enum SyncAction: String, Codable, Sendable { case add, skip, replace }

public struct SyncItem: Equatable, Codable, Sendable {
  public let day: LocalDay
  public let sourceSeconds: Int
  public let targetSeconds: Int
  public let issueKeys: [String]
  public let targetWorklogIDs: [String]
  public let state: SyncState

  public var secondsToAdd: Int { max(0, sourceSeconds - targetSeconds) }
}

public struct SyncPlan: Equatable, Codable, Sendable {
  public let from: LocalDay
  public let to: LocalDay
  public let targetIssue: String
  public let items: [SyncItem]
}

public struct SyncResult: Equatable, Codable, Sendable {
  public let writtenDays: Int
  public let writtenSeconds: Int
  public let collisionsSkipped: Int

  public init(writtenDays: Int, writtenSeconds: Int, collisionsSkipped: Int) {
    self.writtenDays = writtenDays
    self.writtenSeconds = writtenSeconds
    self.collisionsSkipped = collisionsSkipped
  }
}

public struct TimeReportEngine: Sendable {
  public let settings: AppSettings
  private let source: any JiraAccess
  private let target: (any JiraAccess)?

  public init(settings: AppSettings, source: any JiraAccess, target: (any JiraAccess)? = nil) {
    self.settings = settings
    self.source = source
    self.target = target
  }

  public static func live(settings: AppSettings) -> Self {
    Self(
      settings: settings,
      source: JiraClient(credentials: settings.source),
      target: settings.target.map { JiraClient(credentials: $0) }
    )
  }

  public func refresh(now: LocalDay = LocalDay(Date()), checkedAt: Date = Date()) async throws -> ReportSnapshot {
    let expected = Int(settings.workdayHours * 3600)
    let window = Reporting.reportWindow(now: now)
    let sourceUser = try await source.currentUser()
    let sourceDays = try await source.dailyWorklogs(userID: sourceUser.id, from: window.lowerBound, to: window.upperBound)
    var targetDays: [LocalDay: DayTotal]?
    var targetError: String?
    if settings.synchronizationEnabled {
      do {
        guard let target else { throw SettingsError.invalidTarget }
        let targetUser = try await target.currentUser()
        targetDays = try await target.issueWorklogs(issue: settings.targetIssue, userID: targetUser.id)
      } catch {
        targetError = error.localizedDescription
      }
    }
    let reports = Reporting.analyze(now: now, expectedSeconds: expected, sourceDays: sourceDays, targetDays: targetDays)
    let timestamp = Self.iso(checkedAt)
    return ReportSnapshot(
      checkedAt: timestamp,
      lastSuccessfulAt: timestamp,
      syncEnabled: settings.synchronizationEnabled,
      seconds: sourceDays[now]?.seconds ?? 0,
      expectedSeconds: expected,
      targetError: targetError,
      today: reports.today,
      yesterday: reports.yesterday,
      week: reports.week,
      month: reports.month,
      underreported: reports.underreported,
      monthCapacity: reports.monthCapacity
    )
  }

  public func reminder(now: LocalDay = LocalDay(Date())) async throws -> ReminderDecision {
    let expected = Int(settings.workdayHours * 3600)
    let window = Reporting.reportWindow(now: now)
    let user = try await source.currentUser()
    let days = try await source.dailyWorklogs(userID: user.id, from: window.lowerBound, to: window.upperBound)
    let analysis = Reporting.analyze(now: now, expectedSeconds: expected, sourceDays: days)
    let missing = analysis.underreported.map { MissingDay(date: $0, sourceSeconds: days[$0]?.seconds ?? 0) }
    guard !missing.isEmpty else { return ReminderDecision(missingDays: [], message: nil) }
    var parts: [String] = []
    if let today = missing.first(where: { $0.date == now }) {
      parts.append("Dzisiaj masz \(Self.hours(today.sourceSeconds)) z oczekiwanych \(Self.hours(expected)) h w Jirze.")
    }
    let earlier = missing.filter { $0.date != now }.map {
      String(format: "%02d.%02d (%@/%@ h)", $0.date.day, $0.date.month, Self.hours($0.sourceSeconds), Self.hours(expected))
    }
    if !earlier.isEmpty { parts.append("Niepełne poprzednie dni: \(earlier.joined(separator: ", ")).") }
    return ReminderDecision(missingDays: missing, message: parts.joined(separator: " "))
  }

  public func syncPlan(from: LocalDay, to: LocalDay) async throws -> SyncPlan {
    guard settings.synchronizationEnabled, let target else { throw SettingsError.invalidTarget }
    async let sourceUser = source.currentUser()
    async let targetUser = target.currentUser()
    let users = try await (sourceUser, targetUser)
    async let sourceDays = source.dailyWorklogs(userID: users.0.id, from: from, to: to)
    async let targetDays = target.issueWorklogs(issue: settings.targetIssue, userID: users.1.id)
    let (sourceValues, targetValues) = try await (sourceDays, targetDays)
    let items = sourceValues.keys.sorted().map { day in
      let source = sourceValues[day]!
      let destination = targetValues[day, default: DayTotal()]
      let state: SyncState = destination.seconds < source.seconds ? .add : destination.seconds == source.seconds ? .synced : .collision
      return SyncItem(
        day: day,
        sourceSeconds: source.seconds,
        targetSeconds: destination.seconds,
        issueKeys: source.issueKeys,
        targetWorklogIDs: destination.worklogIDs,
        state: state
      )
    }
    return SyncPlan(from: from, to: to, targetIssue: settings.targetIssue, items: items)
  }

  public func execute(_ plan: SyncPlan, actions: [LocalDay: SyncAction] = [:]) async throws -> SyncResult {
    guard settings.synchronizationEnabled, let target else { throw SettingsError.invalidTarget }
    var writtenDays = 0
    var writtenSeconds = 0
    var collisions = 0
    for item in plan.items {
      let action = actions[item.day] ?? (item.state == .add ? .add : .skip)
      if action == .skip {
        if item.state == .collision { collisions += 1 }
        continue
      }
      if action == .replace {
        for id in item.targetWorklogIDs { try await target.deleteWorklog(issue: plan.targetIssue, id: id) }
      }
      let seconds = action == .add && item.state == .add
        ? item.secondsToAdd
        : item.sourceSeconds
      let comment = settings.commentIssueKeys ? item.issueKeys.joined(separator: ", ") : nil
      try await target.addWorklog(issue: plan.targetIssue, day: item.day, seconds: seconds, comment: comment)
      writtenDays += 1
      writtenSeconds += seconds
    }
    return SyncResult(writtenDays: writtenDays, writtenSeconds: writtenSeconds, collisionsSkipped: collisions)
  }

  private static func hours(_ seconds: Int) -> String { String(format: "%.2f", Double(seconds) / 3600) }
  public static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.string(from: date)
  }
}

public actor SnapshotStore {
  private let file: URL

  public init(file: URL = SettingsStore.defaultDirectory.appendingPathComponent("status.json")) {
    self.file = file
  }

  public func read() -> ReportSnapshot? {
    try? JSONDecoder().decode(ReportSnapshot.self, from: Data(contentsOf: file))
  }

  @discardableResult
  public func refresh(using engine: TimeReportEngine, now: LocalDay = LocalDay(Date()), checkedAt: Date = Date()) async throws -> ReportSnapshot {
    let state: ReportSnapshot
    do {
      state = try await engine.refresh(now: now, checkedAt: checkedAt)
    } catch {
      var previous = read() ?? ReportSnapshot(
        checkedAt: TimeReportEngine.iso(checkedAt),
        syncEnabled: engine.settings.synchronizationEnabled,
        expectedSeconds: Int(engine.settings.workdayHours * 3600)
      )
      previous.checkedAt = TimeReportEngine.iso(checkedAt)
      previous.syncEnabled = engine.settings.synchronizationEnabled
      previous.expectedSeconds = Int(engine.settings.workdayHours * 3600)
      previous.error = error.localizedDescription
      previous.targetError = nil
      state = previous
    }
    try write(state)
    if let error = state.error ?? state.targetError { throw RuntimeError.savedFailure(error) }
    return state
  }

  private func write(_ value: ReportSnapshot) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".status.\(UUID().uuidString).tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: temporary, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: file)
    }
  }
}

public enum RuntimeError: LocalizedError {
  case savedFailure(String)
  public var errorDescription: String? {
    switch self { case .savedFailure(let message): message }
  }
}
