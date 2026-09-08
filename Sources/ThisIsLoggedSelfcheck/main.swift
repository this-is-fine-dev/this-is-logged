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
precondition(!legacy.calendarIntegrationEnabled && legacy.calendarIdentifier.isEmpty && legacy.catchAllIssue == "RPR-18")
var calendarSettings = legacy
calendarSettings.calendarIntegrationEnabled = true
do {
  _ = try calendarSettings.validated()
  preconditionFailure("Kalendarz bez wyboru powinien być odrzucony")
} catch SettingsError.invalidCalendar {}
calendarSettings.calendarIdentifier = "work-calendar"
let validatedCalendarSettings = try calendarSettings.validated()
precondition(validatedCalendarSettings.catchAllIssue == "RPR-18")

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
let ignoredFile = activityDirectory.appendingPathComponent("ignored.sqlite")
_ = try ActivityStore(file: ignoredFile).recordClaudeHook(Data(#"{"hook_event_name":"PostToolUse","session_id":"noise","tool_input":{"large":"payload"}}"#.utf8))
precondition(!FileManager.default.fileExists(atPath: ignoredFile.path))
var activityCalendar = Calendar(identifier: .gregorian)
activityCalendar.timeZone = .current
let activityDay = activityCalendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9))!
let currentWorkRange = CalendarIntegration.workRange(
  on: activityDay,
  now: activityDay.addingTimeInterval(2 * 60 * 60),
  workdayHours: 8
)
precondition(currentWorkRange?.duration == 3 * 60 * 60)
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
let activity = try activityStore.activity(on: activityDay)
precondition(firstActivity.issueKey == "ABC-123" && activity.events.count == 4)
precondition(activity.events.allSatisfy { ["UserPromptSubmit", "Stop"].contains($0.kind) })
precondition(activity.allocations.reduce(0) { $0 + $1.minutes } == 60)
precondition(activity.allocations.allSatisfy { $0.minutes % 5 == 0 })
precondition(activity.allocations.contains { $0.issueKey == "ABC-123" })
precondition(activity.allocations.contains { $0.issueKey == "DEF-2" })
let loggedOtherTask = try activityStore.activity(
  on: activityDay,
  now: activityDay.addingTimeInterval(2 * 60 * 60),
  targetMinutes: 80,
  loggedSecondsByIssue: ["RPR-18": 15 * 60]
)
precondition(loggedOtherTask.allocations.reduce(0) { $0 + $1.minutes } == 80)
precondition(loggedOtherTask.allocations.contains {
  $0.issueKey == "RPR-18" && $0.minutes == 15 && $0.loggedMinutes == 15
})

let burstStore = ActivityStore(file: activityDirectory.appendingPathComponent("burst.sqlite"))
for index in 0..<6 {
  let prompt = activityDay.addingTimeInterval(Double(index * 60))
  _ = try burstStore.recordClaudeHook(hook("UserPromptSubmit", session: "burst-\(index)", text: "ABC-123"), now: prompt)
  _ = try burstStore.recordClaudeHook(hook("Stop", session: "burst-\(index)"), now: prompt.addingTimeInterval(50))
}
let burst = try burstStore.activity(on: activityDay, now: activityDay.addingTimeInterval(5 * 60 + 50))
precondition(burst.allocations.first { $0.issueKey == "ABC-123" }?.minutes == 5)
let readingStore = ActivityStore(file: activityDirectory.appendingPathComponent("reading.sqlite"))
_ = try readingStore.recordClaudeHook(hook("UserPromptSubmit", session: "reading", text: "READ-1"), now: activityDay)
_ = try readingStore.recordClaudeHook(hook("Stop", session: "reading"), now: activityDay.addingTimeInterval(60))
_ = try readingStore.recordClaudeHook(hook("UserPromptSubmit", session: "reading", text: "READ-1"), now: activityDay.addingTimeInterval(10 * 60))
let reading = try readingStore.activity(on: activityDay, now: activityDay.addingTimeInterval(10 * 60 + 1))
precondition(reading.allocations == [ActivityAllocation(issueKey: "READ-1", minutes: 10, evidence: 2)])
let normalized = try readingStore.activity(on: activityDay, now: activityDay.addingTimeInterval(60 * 60), targetMinutes: 60)
precondition(normalized.allocations == [ActivityAllocation(issueKey: "READ-1", minutes: 60, evidence: 2)])
precondition(normalized.observedMinutes == 40 && normalized.inferredMinutes == 20)
let partlyLogged = try readingStore.activity(
  on: activityDay,
  now: activityDay.addingTimeInterval(60 * 60),
  targetMinutes: 60,
  loggedSecondsByIssue: ["READ-1": 15 * 60]
)
precondition(partlyLogged.allocations == [
  ActivityAllocation(issueKey: "READ-1", minutes: 60, evidence: 2, loggedMinutes: 15),
])
precondition(partlyLogged.loggedMinutes == 15 && partlyLogged.observedMinutes == 25 && partlyLogged.inferredMinutes == 20)
let meeting = DateInterval(
  start: activityDay.addingTimeInterval(15 * 60),
  end: activityDay.addingTimeInterval(45 * 60)
)
let overlappingMeeting = DateInterval(
  start: activityDay.addingTimeInterval(30 * 60),
  end: activityDay.addingTimeInterval(60 * 60)
)
let calendarActivity = try readingStore.activity(
  on: activityDay,
  now: activityDay.addingTimeInterval(60 * 60),
  targetMinutes: 60,
  reservedIntervals: [meeting, overlappingMeeting],
  fallbackIssue: "RPR-18"
)
precondition(calendarActivity.allocations == [
  ActivityAllocation(issueKey: "RPR-18", minutes: 45, evidence: 2),
  ActivityAllocation(issueKey: "READ-1", minutes: 15, evidence: 2),
])
precondition(calendarActivity.observedMinutes == 60 && calendarActivity.inferredMinutes == 0)
let loggedCalendarActivity = try readingStore.activity(
  on: activityDay,
  now: activityDay.addingTimeInterval(60 * 60),
  targetMinutes: 60,
  reservedIntervals: [meeting, overlappingMeeting],
  loggedSecondsByIssue: ["RPR-18": 30 * 60],
  fallbackIssue: "RPR-18"
)
precondition(loggedCalendarActivity.allocations == [
  ActivityAllocation(issueKey: "RPR-18", minutes: 45, evidence: 2, loggedMinutes: 30),
  ActivityAllocation(issueKey: "READ-1", minutes: 15, evidence: 2),
])
precondition(loggedCalendarActivity.loggedMinutes == 30 && loggedCalendarActivity.observedMinutes == 30)
let generalStore = ActivityStore(file: activityDirectory.appendingPathComponent("general.sqlite"))
_ = try generalStore.recordClaudeHook(hook("UserPromptSubmit", session: "general", text: "Porozmawiajmy o architekturze"), now: activityDay)
let generalActivity = try generalStore.activity(
  on: activityDay,
  now: activityDay.addingTimeInterval(60 * 60),
  targetMinutes: 60,
  fallbackIssue: "RPR-18"
)
precondition(generalActivity.allocations == [ActivityAllocation(issueKey: "RPR-18", minutes: 60, evidence: 1)])
let stickyStore = ActivityStore(file: activityDirectory.appendingPathComponent("sticky.sqlite"))
_ = try stickyStore.recordClaudeHook(hook("UserPromptSubmit", session: "sticky", text: "Napraw STK-1"), now: activityDay)
let inherited = try stickyStore.recordClaudeHook(
  hook("UserPromptSubmit", session: "sticky", text: "Dokończ testy"),
  now: activityDay.addingTimeInterval(5 * 60)
)
precondition(inherited.issueKey == "STK-1")
try stickyStore.suggest(eventIDs: [inherited.eventID], issueKey: "STK-2")
let corrected = try stickyStore.recordClaudeHook(
  hook("UserPromptSubmit", session: "sticky", text: "Jeszcze jedna poprawka"),
  now: activityDay.addingTimeInterval(10 * 60)
)
precondition(corrected.issueKey == "STK-2")
let liveStore = ActivityStore(file: activityDirectory.appendingPathComponent("live.sqlite"))
_ = try liveStore.recordClaudeHook(hook("UserPromptSubmit", session: "live", text: "LIVE-1"), now: activityDay)
let live = try liveStore.activity(on: activityDay, now: activityDay.addingTimeInterval(4 * 60))
precondition(live.allocations == [ActivityAllocation(issueKey: "LIVE-1", minutes: 5, evidence: 1)])
let disposable = try liveStore.recordClaudeHook(hook("UserPromptSubmit", session: "noise", text: "hej"), now: activityDay.addingTimeInterval(5 * 60))
let discarded = try liveStore.discard(eventID: disposable.eventID)
let afterDiscard = try liveStore.activity(on: activityDay)
precondition(discarded && afterDiscard.events.allSatisfy { $0.id != disposable.eventID } && afterDiscard.allocations == live.allocations)

let compactStore = ActivityStore(file: activityDirectory.appendingPathComponent("compact.sqlite"))
_ = try compactStore.recordClaudeHook(
  hook("UserPromptSubmit", session: "compact", text: "CMP-1 " + String(repeating: "x", count: 10_000)),
  now: activityDay
)
let compactMCP = ClaudeMCPServer(store: compactStore)
let compactResponse = compactMCP.response(to: [
  "jsonrpc": "2.0", "id": 2, "method": "tools/call",
  "params": ["name": "get_activity", "arguments": ["date": "2026-09-03", "limit": 1_000]],
])!
let compactData = try JSONSerialization.data(withJSONObject: compactResponse)
let compactActivity = try compactStore.activity(on: activityDay)
precondition(compactData.count < 4_000 && compactActivity.events.first?.text?.count == 1_000)

let integration = ClaudeCodeIntegration(home: activityDirectory)
let existingHooks: [String: Any] = ["hooks": [
  "UserPromptSubmit": [["matcher": "", "hooks": [
    ["type": "command", "command": "custom-hook"],
    ["type": "command", "command": "old --ingest-claude-hook", "async": false],
  ]]],
  "Stop": [["matcher": "", "hooks": [["type": "command", "command": "old --ingest-claude-hook"]]]],
]]
let installedHooks = integration.hooksSettings(from: existingHooks, command: "new --ingest-claude-hook", enabled: true)
let installedJSON = String(data: try JSONSerialization.data(withJSONObject: installedHooks), encoding: .utf8)!
precondition(installedJSON.contains("custom-hook") && installedJSON.contains("new --ingest-claude-hook") && !installedJSON.contains("old --ingest-claude-hook"))
precondition(!installedJSON.contains("MessageDisplay") && !installedJSON.contains("PostToolUse"))
precondition(installedJSON.contains("mcp__this-is-logged__get_activity"))
precondition(installedJSON.contains("mcp__this-is-logged__discard_event"))
let installedHookGroups = (installedHooks["hooks"] as? [String: Any])?.values
  .flatMap { $0 as? [[String: Any]] ?? [] } ?? []
let managedHookCommands = installedHookGroups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
  .filter { ($0["command"] as? String)?.contains("--ingest-claude-hook") == true }
precondition(!managedHookCommands.isEmpty && managedHookCommands.allSatisfy { $0["async"] as? Bool == true })
let removedHooks = integration.hooksSettings(from: installedHooks, command: "", enabled: false)
let removedJSON = String(data: try JSONSerialization.data(withJSONObject: removedHooks), encoding: .utf8)!
precondition(removedJSON.contains("custom-hook") && !removedJSON.contains("--ingest-claude-hook"))
precondition(!removedJSON.contains("mcp__this-is-logged__get_activity"))

let mcp = ClaudeMCPServer(store: activityStore)
let mcpResponse = mcp.response(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
let mcpTools = ((mcpResponse?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
precondition(mcpTools.map { $0["name"] as? String }.compactMap { $0 } == ["get_activity", "discard_event", "suggest_attribution", "review_day"])
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
    let byIssue = try await client.worklogSecondsByIssue(userID: user.id, on: LocalDay("2026-09-01")!)
    precondition(byIssue == ["WP-1": 3600, "WP-2": 1800])
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
      LocalDay("2026-09-03")!: DayTotal(seconds: 7200, worklogIDs: ["old-3"]),
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
    precondition(plan.items.map(\.state) == [.add, .synced, .collision])
    let automatic = try await engine.execute(plan)
    precondition(automatic == SyncResult(writtenDays: 1, writtenSeconds: 3600, collisionsSkipped: 1))
    let interactive = try await engine.execute(plan, actions: [LocalDay("2026-09-03")!: .replace])
    let deleted = await targetJira.deleted
    precondition(interactive.writtenDays == 2 && deleted == ["old-3"])

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
