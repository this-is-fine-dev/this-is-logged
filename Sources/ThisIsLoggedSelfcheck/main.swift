import Foundation
import ThisIsLoggedCore

final class StubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var requests: [URLRequest] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    Self.requests.append(request)
    let path = request.url!.path
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let start = Int(query.first { $0.name == "startAt" }?.value ?? "0") ?? 0
    let body: String
    if path.hasSuffix("/myself") {
      body = #"{"accountId":"u1","displayName":"Fine"}"#
    } else if path.hasSuffix("/search") {
      body = start == 0
        ? #"{"issues":[{"key":"WP-1","fields":{"summary":"One"}}],"total":2}"#
        : #"{"issues":[{"key":"WP-2","fields":{"summary":"Two"}}],"total":2}"#
    } else if path.hasSuffix("/issue/WP-1/worklog") {
      body = start == 0
        ? #"{"worklogs":[{"id":"1","started":"2026-09-01T10:00:00.000+0200","timeSpentSeconds":3600,"author":{"accountId":"u1"}}],"total":2,"startAt":0}"#
        : #"{"worklogs":[{"id":"2","started":"2026-09-01T11:00:00.000+0200","timeSpentSeconds":999,"author":{"accountId":"other"}}],"total":2,"startAt":1}"#
    } else if path.hasSuffix("/issue/WP-2/worklog") {
      body = #"{"worklogs":[{"id":"3","started":"2026-09-01T12:00:00.000+0200","timeSpentSeconds":1800,"author":{"accountId":"u1"}}],"total":1,"startAt":0}"#
    } else if path.hasSuffix("/issue/AUT-1/worklog"), request.httpMethod == "POST" {
      body = #"{"id":"4","started":"2026-09-01T09:00:00.000+0000","timeSpentSeconds":5400,"author":{"accountId":"u1"}}"#
    } else if path.hasSuffix("/issue/AUT-1") {
      body = #"{"key":"AUT-1","fields":{"summary":"Timesheet"}}"#
    } else {
      body = ""
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

final class FailureBox: @unchecked Sendable { var error: Error? }

actor FakeJira: JiraAccess {
  let user: JiraUser
  let daily: [LocalDay: DayTotal]
  let issue: [LocalDay: DayTotal]
  var added: [LocalDay] = []
  var deleted: [String] = []

  init(user: String, daily: [LocalDay: DayTotal] = [:], issue: [LocalDay: DayTotal] = [:]) {
    self.user = JiraUser(id: user, displayName: user)
    self.daily = daily
    self.issue = issue
  }

  func currentUser() async throws -> JiraUser { user }
  func dailyWorklogs(userID: String, from: LocalDay, to: LocalDay) async throws -> [LocalDay: DayTotal] {
    daily.filter { $0.key >= from && $0.key <= to }
  }
  func issueWorklogs(issue: String, userID: String) async throws -> [LocalDay: DayTotal] { self.issue }
  func issueSummary(_ issue: String) async throws -> String { issue }
  func addWorklog(issue: String, day: LocalDay, seconds: Int, comment: String?) async throws { added.append(day) }
  func deleteWorklog(issue: String, id: String) async throws { deleted.append(id) }
}

struct FailingJira: JiraAccess {
  struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
  func currentUser() async throws -> JiraUser { throw Offline() }
  func dailyWorklogs(userID: String, from: LocalDay, to: LocalDay) async throws -> [LocalDay: DayTotal] { throw Offline() }
  func issueWorklogs(issue: String, userID: String) async throws -> [LocalDay: DayTotal] { throw Offline() }
  func issueSummary(_ issue: String) async throws -> String { throw Offline() }
  func addWorklog(issue: String, day: LocalDay, seconds: Int, comment: String?) async throws { throw Offline() }
  func deleteWorklog(issue: String, id: String) async throws { throw Offline() }
}

let eightHours = 8 * 3600
let now = LocalDay("2026-09-03")!
let source = [
  LocalDay("2026-09-01")!: DayTotal(seconds: 2 * 3600),
  LocalDay("2026-09-02")!: DayTotal(seconds: 8 * 3600),
]
let target = [
  LocalDay("2026-09-01")!: DayTotal(seconds: 3600),
  LocalDay("2026-09-02")!: DayTotal(seconds: 8 * 3600),
]
let reports = Reporting.analyze(now: now, expectedSeconds: eightHours, sourceDays: source, targetDays: target)

precondition(reports.underreported.map(\.description) == ["2026-09-01", "2026-09-03"])
precondition(reports.week.from.description == "2026-08-31" && reports.week.to.description == "2026-09-02")
precondition(reports.month.missing == [MissingDay(date: LocalDay("2026-09-01")!, sourceSeconds: 7200)])
precondition(reports.month.differences == [TargetDifference(date: LocalDay("2026-09-01")!, sourceSeconds: 7200, targetSeconds: 3600)])
precondition(reports.monthCapacity == MonthCapacity(workingDays: 22, daysOff: 8, expectedSeconds: 633_600, reportedSeconds: 36_000))

let monday = Reporting.analyze(now: LocalDay("2026-09-07")!, expectedSeconds: eightHours, sourceDays: [:])
precondition(monday.week.from.description == "2026-08-31" && monday.week.to.description == "2026-09-06")
precondition(monday.week.workingDays == 5)

let sunday = Reporting.analyze(now: LocalDay("2026-09-06")!, expectedSeconds: eightHours, sourceDays: [
  LocalDay("2026-09-04")!: DayTotal(seconds: eightHours),
])
precondition(sunday.today.workingDays == 0)
precondition(sunday.yesterday.from.description == "2026-09-04" && sunday.yesterday.sourceSeconds == eightHours)
precondition(sunday.week.missing.count == 4)

let christmas = Reporting.analyze(now: LocalDay("2026-12-28")!, expectedSeconds: eightHours, sourceDays: [:])
precondition(christmas.month.missing.contains { $0.date.description == "2026-12-23" })
precondition(!christmas.month.missing.contains { ["2026-12-24", "2026-12-25", "2026-12-26"].contains($0.date.description) })

let august = Reporting.analyze(now: LocalDay("2026-08-03")!, expectedSeconds: eightHours, sourceDays: [:])
precondition(august.monthCapacity.workingDays == 21)

let monitoring = Reporting.analyze(now: now, expectedSeconds: eightHours, sourceDays: [:])
precondition(monitoring.today.targetSeconds == nil && monitoring.today.differences == nil)
precondition(LocalDay("2026-02-30") == nil && LocalDay("2026-2-01") == nil)
precondition(LocalDay("2024-02-29")?.adding(days: 1).description == "2024-03-01")

let legacy = try SettingsStore.parseLegacy("""
SRC_URL=firma.atlassian.net
SRC_EMAIL=fine@example.com
SRC_TOKEN=source
SYNC_ENABLED=1
DST_URL=https://target.example.com/
DST_TOKEN=target=x
DST_ISSUE=aut-1
REMINDER_TIME=16:00
SYNC_TIME=23:00
WORKDAY_HOURS=7,5
""").validated()
precondition(legacy.source.url.absoluteString == "https://firma.atlassian.net")
precondition(legacy.synchronizationEnabled && legacy.targetIssue == "AUT-1" && legacy.target?.token == "target=x")
precondition(legacy.workdayHours == 7.5)

var claudeOnlyChange = legacy
claudeOnlyChange.claudeIntegrationEnabled = true
let claudeOnlyVerification = claudeOnlyChange.jiraVerification(comparedTo: legacy)
precondition(!claudeOnlyVerification.source && !claudeOnlyVerification.target,
             "Zmiana lokalnej integracji Claude Code nie może wymagać połączenia z Jirą")
var sourceChange = legacy
sourceChange.source.token = "changed"
let sourceVerification = sourceChange.jiraVerification(comparedTo: legacy)
precondition(sourceVerification.source && !sourceVerification.target)
var targetChange = legacy
targetChange.targetIssue = "AUT-2"
let targetVerification = targetChange.jiraVerification(comparedTo: legacy)
precondition(!targetVerification.source && targetVerification.target)
let initialVerification = legacy.jiraVerification(comparedTo: nil)
precondition(initialVerification.source && initialVerification.target)

let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let settingsFile = settingsDirectory.appendingPathComponent("settings.json")
let settingsStore = SettingsStore(file: settingsFile, legacyFile: settingsDirectory.appendingPathComponent("legacy.env"))
try settingsStore.save(legacy)
let savedSettings = try settingsStore.load()
precondition(savedSettings == legacy)
let settingsJSON = try String(contentsOf: settingsFile, encoding: .utf8)
precondition(settingsJSON.contains("source") && settingsJSON.contains("target=x"))
let permissions = try FileManager.default.attributesOfItem(atPath: settingsFile.path)[.posixPermissions] as? NSNumber
precondition(permissions?.intValue == 0o600)
try FileManager.default.removeItem(at: settingsDirectory)

let activityDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let activityStore = ActivityStore(file: activityDirectory.appendingPathComponent("activity.sqlite"))
var activityCalendar = Calendar(identifier: .gregorian)
activityCalendar.timeZone = .current
let activityDay = activityCalendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9))!
func hook(_ event: String, session: String, text: String? = nil) -> Data {
  var value = ["hook_event_name": event, "session_id": session, "cwd": ""]
  if let text { value[event == "UserPromptSubmit" ? "prompt" : "last_assistant_message"] = text }
  return try! JSONSerialization.data(withJSONObject: value)
}
let firstActivity = try activityStore.recordClaudeHook(hook("UserPromptSubmit", session: "one", text: "Zrób ABC-123"), now: activityDay)
_ = try activityStore.recordClaudeHook(hook("Stop", session: "one"), now: activityDay.addingTimeInterval(12 * 60))
let secondActivity = try activityStore.recordClaudeHook(hook("UserPromptSubmit", session: "two", text: "Popraw formularz"), now: activityDay.addingTimeInterval(60 * 60))
_ = try activityStore.recordClaudeHook(hook("Stop", session: "two"), now: activityDay.addingTimeInterval(80 * 60))
let firstChunk = try JSONSerialization.data(withJSONObject: [
  "hook_event_name": "MessageDisplay", "session_id": "two", "cwd": "", "message_id": "message-1", "index": 0, "delta": "Hello ",
])
let secondChunk = try JSONSerialization.data(withJSONObject: [
  "hook_event_name": "MessageDisplay", "session_id": "two", "cwd": "", "message_id": "message-1", "index": 1, "delta": "world", "final": true,
])
_ = try activityStore.recordClaudeHook(firstChunk, now: activityDay.addingTimeInterval(70 * 60))
_ = try activityStore.recordClaudeHook(secondChunk, now: activityDay.addingTimeInterval(71 * 60))
try activityStore.suggest(eventIDs: [secondActivity.eventID], issueKey: "DEF-2", summary: "Formularz", confidence: 0.9)
let activity = try activityStore.activity(on: activityDay, targetMinutes: 60)
precondition(firstActivity.issueKey == "ABC-123" && activity.events.count == 5)
precondition(activity.events.first { $0.kind == "MessageDisplay" }?.text == "Hello world")
precondition(activity.allocations.reduce(0) { $0 + $1.minutes } == 60)
precondition(activity.allocations.allSatisfy { $0.minutes % 5 == 0 })
precondition(activity.allocations.contains { $0.issueKey == "ABC-123" })
precondition(activity.allocations.contains { $0.issueKey == "DEF-2" })
precondition(activity.allocations.contains { $0.issueKey == "Nieprzypisane" })
try activityStore.saveReview(day: activity.day, status: .rejected, allocations: activity.allocations)
let savedReview = try activityStore.review(day: activity.day)
precondition(savedReview?.status == .rejected && savedReview?.allocations == activity.allocations)

let integration = ClaudeCodeIntegration(home: activityDirectory)
let existingHooks: [String: Any] = ["hooks": [
  "UserPromptSubmit": [["matcher": "", "hooks": [["type": "command", "command": "custom-hook"]]]],
  "Stop": [["matcher": "", "hooks": [["type": "command", "command": "old --ingest-claude-hook"]]]],
]]
let installedHooks = integration.hooksSettings(from: existingHooks, command: "new --ingest-claude-hook", enabled: true)
let installedJSON = String(data: try JSONSerialization.data(withJSONObject: installedHooks), encoding: .utf8)!
precondition(installedJSON.contains("custom-hook") && installedJSON.contains("new --ingest-claude-hook") && !installedJSON.contains("old --ingest-claude-hook"))
precondition(installedJSON.contains("mcp__this-is-logged__get_activity"))
let removedHooks = integration.hooksSettings(from: installedHooks, command: "", enabled: false)
let removedJSON = String(data: try JSONSerialization.data(withJSONObject: removedHooks), encoding: .utf8)!
precondition(removedJSON.contains("custom-hook") && !removedJSON.contains("--ingest-claude-hook"))
precondition(!removedJSON.contains("mcp__this-is-logged__get_activity"))

let mcp = ClaudeMCPServer(store: activityStore)
let mcpResponse = mcp.response(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
let mcpTools = ((mcpResponse?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
precondition(mcpTools.map { $0["name"] as? String }.compactMap { $0 } == ["get_activity", "suggest_attribution", "review_day"])
try FileManager.default.removeItem(at: activityDirectory)

let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [StubProtocol.self]
let client = JiraClient(
  credentials: JiraCredentials(url: URL(string: "https://jira.example.com")!, email: "fine@example.com", token: "secret"),
  session: URLSession(configuration: configuration)
)
let finished = DispatchSemaphore(value: 0)
let failure = FailureBox()
Task.detached {
  defer { finished.signal() }
  do {
    let user = try await client.currentUser()
    precondition(user == JiraUser(id: "u1", displayName: "Fine"))
    let days = try await client.dailyWorklogs(userID: user.id, from: LocalDay("2026-09-01")!, to: LocalDay("2026-09-30")!)
    precondition(days == [LocalDay("2026-09-01")!: DayTotal(seconds: 5400, issueKeys: ["WP-1", "WP-2"], worklogIDs: ["1", "3"])])
    let summary = try await client.issueSummary("AUT-1")
    precondition(summary == "AUT-1 — Timesheet")
    try await client.addWorklog(issue: "AUT-1", day: LocalDay("2026-09-01")!, seconds: 5400, comment: "WP-1, WP-2")
    try await client.deleteWorklog(issue: "AUT-1", id: "4")

    let sourceJira = FakeJira(user: "source", daily: [
      LocalDay("2026-09-01")!: DayTotal(seconds: 7200, issueKeys: ["WP-1"]),
      LocalDay("2026-09-02")!: DayTotal(seconds: 28_800, issueKeys: ["WP-2"]),
      LocalDay("2026-09-03")!: DayTotal(seconds: 3600, issueKeys: ["WP-3"]),
    ])
    let targetJira = FakeJira(user: "target", issue: [
      LocalDay("2026-09-01")!: DayTotal(seconds: 3600, worklogIDs: ["old-1"]),
      LocalDay("2026-09-02")!: DayTotal(seconds: 28_800, worklogIDs: ["old-2"]),
    ])
    let engineSettings = AppSettings(
      source: JiraCredentials(url: URL(string: "https://source.example.com")!, token: "x"),
      synchronizationEnabled: true,
      target: JiraCredentials(url: URL(string: "https://target.example.com")!, token: "y"),
      targetIssue: "AUT-1"
    )
    let engine = TimeReportEngine(settings: engineSettings, source: sourceJira, target: targetJira)
    let snapshot = try await engine.refresh(now: LocalDay("2026-09-03")!, checkedAt: Date(timeIntervalSince1970: 0))
    precondition(snapshot.today?.sourceSeconds == 3600 && snapshot.month?.differences?.count == 1)
    precondition(snapshot.lastSuccessfulAt == "1970-01-01T00:00:00.000Z")
    let reminder = try await engine.reminder(now: LocalDay("2026-09-03")!)
    precondition(reminder.missingDays.map(\.date.description) == ["2026-09-01", "2026-09-03"])
    precondition(reminder.message?.contains("Dzisiaj masz 1.00") == true)

    let plan = try await engine.syncPlan(from: LocalDay("2026-09-01")!, to: LocalDay("2026-09-03")!)
    precondition(plan.items.map(\.state) == [.collision, .synced, .add])
    let automatic = try await engine.execute(plan)
    precondition(automatic == SyncResult(writtenDays: 1, writtenSeconds: 3600, collisionsSkipped: 1))
    let interactive = try await engine.execute(plan, actions: [LocalDay("2026-09-01")!: .replace])
    let deleted = await targetJira.deleted
    precondition(interactive.writtenDays == 2 && deleted == ["old-1"])

    let activityJira = FakeJira(user: "activity")
    let activityResult = try await ActivityJiraLogger(jira: activityJira).log(activity)
    precondition(activityResult.writtenIssues == 2 && activityResult.skippedIssues == 0 && activityResult.writtenMinutes == 30)
    let activityAdded = await activityJira.added
    precondition(activityAdded.count == 2)
    let conflictingJira = FakeJira(user: "activity", issue: [LocalDay("2026-09-03")!: DayTotal(seconds: 300)])
    do {
      _ = try await ActivityJiraLogger(jira: conflictingJira).log(activity)
      preconditionFailure("activity conflict should stop the write")
    } catch is ActivityLoggingError {}
    let conflictingAdded = await conflictingJira.added
    precondition(conflictingAdded.isEmpty)
    let overflowingJira = FakeJira(user: "activity", daily: [LocalDay("2026-09-03")!: DayTotal(seconds: 40 * 60)])
    do {
      _ = try await ActivityJiraLogger(jira: overflowingJira).log(activity)
      preconditionFailure("daily overflow should stop the write")
    } catch is ActivityLoggingError {}
    let overflowingAdded = await overflowingJira.added
    precondition(overflowingAdded.isEmpty)

    let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = SnapshotStore(file: cacheDirectory.appendingPathComponent("status.json"))
    _ = try await cache.refresh(using: engine, now: LocalDay("2026-09-03")!, checkedAt: Date(timeIntervalSince1970: 0))
    let failing = TimeReportEngine(settings: engineSettings, source: FailingJira(), target: targetJira)
    do {
      _ = try await cache.refresh(using: failing, now: LocalDay("2026-09-03")!, checkedAt: Date(timeIntervalSince1970: 60))
      preconditionFailure("offline refresh should fail")
    } catch {}
    let cached = await cache.read()
    precondition(cached?.today?.sourceSeconds == 3600 && cached?.lastSuccessfulAt == "1970-01-01T00:00:00.000Z")
    precondition(cached?.error == "offline")
    try? FileManager.default.removeItem(at: cacheDirectory)
  } catch {
    failure.error = error
  }
}
finished.wait()
if let error = failure.error { fatalError(String(describing: error)) }
precondition(StubProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic ZmluZUBleGFtcGxlLmNvbTpzZWNyZXQ=" })
precondition(StubProtocol.requests.contains { $0.httpMethod == "POST" })
precondition(StubProtocol.requests.contains { $0.httpMethod == "DELETE" })

print("ok")
