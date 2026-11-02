import Foundation
import ThisIsLoggedCore

func checkAutomationPause() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = SnapshotStore(file: directory.appendingPathComponent("status.json"))
  let day = LocalDay("2026-09-03")!
  let window = Reporting.synchronizationWindow(now: day)
  let days = Dictionary(uniqueKeysWithValues: Reporting.workdays(from: window.lowerBound, through: day).map {
    ($0, DayTotal(seconds: 28_800))
  })
  let source = FakeJira(user: "source", daily: days)
  let settings = AppSettings(source: JiraCredentials(url: URL(string: "https://source.example.com")!, token: "x"))
  let engine = TimeReportEngine(settings: settings, source: source)
  let complete = try await cache.refresh(using: engine, now: day, checkedAt: day.date)
  precondition(engine.automationIsComplete(complete, on: day), "A fully reported day must pause automatic Jira access")
  let offline = TimeReportEngine(settings: settings, source: FailingJira())
  let paused = await cache.automationPaused(using: offline, on: day)
  precondition(paused, "Disconnecting VPN must not resume automatic Jira access")
  let afterVPNDisconnect = try await cache.refresh(using: offline, now: day, checkedAt: day.date.addingTimeInterval(60))
  precondition(afterVPNDisconnect == complete, "A completed report must not turn into an offline error")
  precondition(!engine.automationIsComplete(complete, on: day.adding(days: 1)), "Monitoring must resume the next day")
  var failed = complete
  failed.error = "offline"
  precondition(!engine.automationIsComplete(failed, on: day))
  var legacy = complete
  legacy.automationIdentity = nil
  precondition(!engine.automationIsComplete(legacy, on: day), "An older snapshot needs one live verification")
  var stale = complete
  stale.lastSuccessfulAt = TimeReportEngine.iso(day.adding(days: -1).date)
  precondition(!engine.automationIsComplete(stale, on: day))
  var incompleteDays = days
  incompleteDays[day] = DayTotal(seconds: 14_400)
  let incomplete = try await TimeReportEngine(settings: settings, source: FakeJira(user: "source", daily: incompleteDays))
    .refresh(now: day, checkedAt: day.date)
  precondition(!engine.automationIsComplete(incomplete, on: day))
  incompleteDays = days
  incompleteDays[day.adding(days: -1)] = DayTotal(seconds: 0)
  let missingEarlier = try await TimeReportEngine(settings: settings, source: FakeJira(user: "source", daily: incompleteDays))
    .refresh(now: day, checkedAt: day.date)
  precondition(!engine.automationIsComplete(missingEarlier, on: day))
  var changedSettings = settings
  changedSettings.source.token = "changed"
  precondition(!TimeReportEngine(settings: changedSettings, source: source).automationIsComplete(complete, on: day))
  changedSettings = settings
  changedSettings.workdayHours = 9
  precondition(!TimeReportEngine(settings: changedSettings, source: source).automationIsComplete(complete, on: day))
  try await cache.resumeAutomation()
  let manuallyResumed = await cache.automationPaused(using: engine, on: day)
  precondition(!manuallyResumed, "Manual refresh must bypass the daily pause")
  do {
    _ = try await cache.refresh(using: offline, now: day, checkedAt: day.date)
    preconditionFailure("Manual refresh must contact Jira even after completion")
  } catch {}

  var syncSettings = settings
  syncSettings.synchronizationEnabled = true
  syncSettings.target = JiraCredentials(url: URL(string: "https://target.example.com")!, token: "y")
  syncSettings.targetIssue = "AUT-1"
  let target = FakeJira(user: "target", issue: days)
  let syncing = TimeReportEngine(settings: syncSettings, source: source, target: target)
  let unverifiedSync = try await cache.refresh(using: syncing, now: day, checkedAt: day.date)
  precondition(!syncing.automationIsComplete(unverifiedSync, on: day), "Status alone must not skip synchronization of the previous month")
  let plan = try await syncing.syncPlan(from: window.lowerBound, to: window.upperBound)
  _ = try await syncing.execute(plan)
  let synchronized = try await cache.refresh(using: syncing, now: day, checkedAt: day.date, completedSync: plan)
  precondition(syncing.automationIsComplete(synchronized, on: day))
  syncSettings.targetIssue = "AUT-2"
  precondition(!TimeReportEngine(settings: syncSettings, source: source, target: target).automationIsComplete(synchronized, on: day))
  try await cache.resumeAutomation()
  var collisionDays = days
  collisionDays[LocalDay("2026-08-03")!] = DayTotal(seconds: 32_400)
  let colliding = TimeReportEngine(settings: syncing.settings, source: source, target: FakeJira(user: "target", issue: collisionDays))
  let collisionPlan = try await colliding.syncPlan(from: window.lowerBound, to: window.upperBound)
  _ = try await colliding.execute(collisionPlan)
  let collision = try await cache.refresh(using: colliding, now: day, checkedAt: day.date, completedSync: collisionPlan)
  precondition(!colliding.automationIsComplete(collision, on: day), "An unresolved previous-month collision must prevent pausing")
}
