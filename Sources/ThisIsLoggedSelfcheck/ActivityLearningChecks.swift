import Foundation
import ThisIsLoggedCore

func checkActivityLearning() throws {
  let now = LocalDay("2026-10-01")!.date
  let firstDay = LocalDay("2026-09-01")!
  let samples = (0..<20).flatMap { index in
    (0..<2).map { task in
      let feature = ActivityFeatures(activeMinutes: Double(20 + (index % 5) * 20 + task * 10), promptCount: 2 + index % 3)
      return ActivityTrainingSample(day: firstDay.adding(days: index), features: feature,
        reportedMinutes: feature.activeMinutes * 1.8 + Double(feature.promptCount) * 3)
    }
  }
  let model = ActivityTimeModel.train(samples, now: now)
  precondition(model.validated && model.dayCount == 20 && model.sampleCount == 40 && model.validationDays == 5)
  precondition(model.modelMAE! < model.baselineMAE! * 0.9)
  precondition(abs(model.predict(ActivityFeatures(activeMinutes: 60, promptCount: 3)) - 117) < 5)
  precondition(model.isUsable(on: LocalDay(now), now: now))
  precondition(!model.isUsable(on: firstDay, now: now), "A model must not predict its own training history")
  precondition(!model.isUsable(on: LocalDay(now).adding(days: 15), now: now.addingTimeInterval(15 * 86400)))
  precondition(model.predict(ActivityFeatures(activeMinutes: 0, promptCount: 0)) == 0)
  let restored = try JSONDecoder().decode(ActivityTimeModel.self, from: JSONEncoder().encode(model))
  precondition(restored.predict(samples[0].features) == model.predict(samples[0].features))
  precondition(!ActivityTimeModel.train(Array(samples.prefix(10)), now: now).validated)
  let baselineWins = samples.map { ActivityTrainingSample(day: $0.day, features: $0.features, reportedMinutes: $0.features.activeMinutes) }
  precondition(!ActivityTimeModel.train(baselineWins, now: now).validated)
  let drift = samples.map {
    ActivityTrainingSample(day: $0.day, features: $0.features,
      reportedMinutes: $0.features.activeMinutes * ($0.day < firstDay.adding(days: 15) ? 2 : 1))
  }
  precondition(!ActivityTimeModel.train(drift, now: now).validated, "Chronological holdout must reject a model that fails on later days")
  let future = samples.map { ActivityTrainingSample(day: LocalDay(now), features: $0.features, reportedMinutes: $0.reportedMinutes) }
  precondition(ActivityTimeModel.train(future, now: now).sampleCount == 0)

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ActivityStore(file: directory.appendingPathComponent("learning.sqlite"))
  func hook(_ issue: String) -> Data {
    Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"test\",\"cwd\":\"\",\"prompt\":\"\(issue)\"}".utf8)
  }
  let oldDate = LocalDay("2026-06-01")!.date
  let old = try store.recordClaudeHook(hook("ABC-1"), now: oldDate)
  _ = try store.recordClaudeHook(hook("ABC-2"), now: now)
  let archived = try store.activity(on: oldDate, now: now)
  precondition(archived.events.contains { $0.id == old.eventID }, "New events must not delete the archive")
  try store.suggest(eventIDs: [old.eventID], issueKey: "ABC-3")
  let attributed = try store.activity(on: oldDate, now: now)
  precondition(attributed.allocations.first?.issueKey == "ABC-3")
  _ = try store.discard(eventID: old.eventID)
  let discarded = try store.activity(on: oldDate, now: now)
  precondition(discarded.allocations.isEmpty, "Discarded archived events must not feed estimates or learning")

  let profile = "test-profile"
  let firstRead = now.addingTimeInterval(-86400)
  func recordDays(at date: Date) throws {
    for index in 0..<20 {
      let a = samples[index * 2], b = samples[index * 2 + 1]
      try store.recordLearningDay(profile: profile, day: a.day, features: ["ABC-1": a.features, "ABC-2": b.features],
        reports: ["ABC-1": Int(a.reportedMinutes * 60), "ABC-2": Int(b.reportedMinutes * 60)], now: date)
    }
  }
  try recordDays(at: firstRead)
  let unconfirmed = try store.trainLearningModel(profile: profile, now: now)
  precondition(unconfirmed.sampleCount == 0, "Time passing alone does not confirm Jira reports")
  try recordDays(at: now)
  let confirmed = try store.trainLearningModel(profile: profile, now: now)
  precondition(confirmed.validated && confirmed.sampleCount == 40)
  try recordDays(at: now)
  let repeated = try store.trainLearningModel(profile: profile, now: now)
  precondition(repeated.sampleCount == 40, "Refreshing must replace examples, not duplicate them")
  let isolated = try store.trainLearningModel(profile: "another-account", now: now)
  precondition(isolated.sampleCount == 0)
  try store.recordLearningDay(profile: profile, day: firstDay,
    features: ["ABC-1": samples[0].features, "ABC-2": samples[1].features], reports: ["ABC-1": 1200, "ABC-2": 2400], now: now)
  let corrected = try store.trainLearningModel(profile: profile, now: now)
  precondition(corrected.sampleCount == 38 && !corrected.validated, "Corrected reports need confirmation again")
  let incompleteDay = firstDay.adding(days: 1)
  for date in [firstRead, now] {
    try store.recordLearningDay(profile: profile, day: incompleteDay,
      features: ["ABC-1": samples[2].features, "ABC-2": samples[3].features], reports: ["ABC-1": 1200], now: date)
  }
  let incomplete = try store.trainLearningModel(profile: profile, now: now)
  precondition(incomplete.sampleCount == 36, "Missing worklogs are unknown, not zero labels")
  let claimed = try store.claimLearningRefresh(profile: profile, now: now)
  let duplicate = try store.claimLearningRefresh(profile: profile, now: now)
  precondition(claimed && !duplicate)
  let retry = try store.claimLearningRefresh(profile: profile, now: now.addingTimeInterval(3601))
  precondition(retry)

  let todayStore = ActivityStore(file: directory.appendingPathComponent("today.sqlite"))
  let workStart = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: now.addingTimeInterval(86400))!
  _ = try todayStore.recordClaudeHook(hook("ABC-1"), now: workStart)
  _ = try todayStore.recordClaudeHook(hook("ABC-2"), now: workStart.addingTimeInterval(1800))
  let end = workStart.addingTimeInterval(3600)
  let estimate = try todayStore.activity(on: workStart, now: end, targetMinutes: 480, fallbackIssue: "GENERAL-1", model: model)
  precondition(estimate.usesLearnedEstimate && estimate.allocations.count == 2)
  precondition(estimate.allocations.reduce(0) { $0 + $1.minutes } < 480, "Learned estimates must not be inflated back to the daily target")
  precondition(estimate.allocations.reduce(0) { $0 + $1.minutes } == 60, "ML must fit the elapsed hour even with an eight-hour target")
  let logged = try todayStore.activity(on: workStart, now: end, targetMinutes: 480,
    loggedSecondsByIssue: ["ABC-1": 300 * 60], fallbackIssue: "GENERAL-1", model: model)
  precondition(logged.allocations.first { $0.issueKey == "ABC-1" }?.minutes == 300, "Logged time is neither reduced nor counted twice")
  precondition(logged.allocations.reduce(0) { $0 + $1.minutes } == 300 && logged.observedMinutes == 0,
    "ML must not add another task when reported time already covers the elapsed day")
  let withMeetings = try todayStore.activity(on: workStart, now: end, targetMinutes: 480,
    reservedIntervals: [DateInterval(start: workStart, duration: 600)], fallbackIssue: "GENERAL-1", model: model)
  precondition(!withMeetings.usesLearnedEstimate, "Calendar-backed days retain the calendar-aware baseline")
  let permission = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("learning.sqlite").path)[.posixPermissions] as? NSNumber
  precondition(permission?.intValue == 0o600)
}

func checkLearningRefresh(client: JiraClient) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ActivityStore(file: directory.appendingPathComponent("activity.sqlite"))
  var settings = AppSettings(source: JiraCredentials(url: URL(string: "https://jira.example.com")!, token: "test"), claudeIntegrationEnabled: true)
  let date = LocalDay("2026-09-01")!.date
  for (index, issue) in ["WP-1", "WP-2"].enumerated() {
    let data = Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sample\",\"prompt\":\"\(issue)\"}".utf8)
    _ = try store.recordClaudeHook(data, now: date.addingTimeInterval(Double(index) * 1800))
  }
  let now = LocalDay("2026-09-05")!.date
  let profile = ActivityStore.learningProfile(settings)
  try await store.refreshLearning(settings: settings, client: client, now: now)
  let initial = try store.learningModel(profile: profile)
  precondition(initial?.sampleCount == 0)
  try await store.refreshLearning(settings: settings, client: client, now: now.addingTimeInterval(86401))
  let confirmed = try store.learningModel(profile: profile)
  precondition(confirmed?.sampleCount == 2 && confirmed?.validated == false)
  let tooSoon = try store.claimLearningRefresh(profile: profile, now: now.addingTimeInterval(86402))
  precondition(!tooSoon)
  let offlineConfiguration = URLSessionConfiguration.ephemeral
  offlineConfiguration.protocolClasses = [LearningOfflineProtocol.self]
  let offline = JiraClient(credentials: settings.source, session: URLSession(configuration: offlineConfiguration))
  do {
    try await store.refreshLearning(settings: settings, client: offline, now: now.addingTimeInterval(2 * 86400 + 2))
    preconditionFailure("Offline refresh must fail without replacing the model")
  } catch is URLError {}
  let preserved = try store.learningModel(profile: profile)
  precondition(preserved?.trainedAt == confirmed?.trainedAt && preserved?.sampleCount == 2)
  try await store.refreshLearning(settings: settings, client: offline, now: now.addingTimeInterval(2 * 86400 + 3))
  let captured = try store.activity(on: date, now: now)
  _ = try store.discard(eventID: captured.events[0].id)
  let invalidated = try store.learningModel(profile: profile)
  precondition(invalidated == nil, "Manual corrections invalidate learned estimates immediately")
  let correctionConfiguration = URLSessionConfiguration.ephemeral
  correctionConfiguration.protocolClasses = [LearningCorrectionProtocol.self]
  LearningCorrectionProtocol.correction = { _ = try store.discard(eventID: captured.events[1].id) }
  defer { LearningCorrectionProtocol.correction = nil }
  let correctionClient = JiraClient(credentials: settings.source, session: URLSession(configuration: correctionConfiguration))
  try await store.refreshLearning(settings: settings, client: correctionClient, now: now.addingTimeInterval(3 * 86400))
  let revoked = try store.learningModel(profile: profile)
  precondition(revoked == nil, "A refresh started before a correction must not resurrect the invalidated model")
  settings.source.token = "another-account"
  precondition(ActivityStore.learningProfile(settings) != profile)
  let absent = try store.learningModel(profile: ActivityStore.learningProfile(settings))
  precondition(absent == nil)
  settings.claudeIntegrationEnabled = false
  try await store.refreshLearning(settings: settings, client: client, now: now)
  let disabled = try store.learningModel(profile: ActivityStore.learningProfile(settings))
  precondition(disabled == nil)
}

private final class LearningOfflineProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
  override func stopLoading() {}
}

private final class LearningCorrectionProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var correction: (() throws -> Void)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      try Self.correction?()
      let body = request.url!.path.hasSuffix("/myself") ? #"{"accountId":"u1"}"# : #"{"issues":[],"total":0}"#
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
