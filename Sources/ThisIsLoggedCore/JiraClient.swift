import Foundation

public struct JiraUser: Equatable, Sendable {
  public let id: String
  public let displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

public protocol JiraAccess: Sendable {
  func currentUser() async throws -> JiraUser
  func dailyWorklogs(userID: String, from: LocalDay, to: LocalDay) async throws -> [LocalDay: DayTotal]
  func issueWorklogs(issue: String, userID: String) async throws -> [LocalDay: DayTotal]
  func issueSummary(_ issue: String) async throws -> String
  func addWorklog(issue: String, day: LocalDay, seconds: Int, comment: String?) async throws
  func deleteWorklog(issue: String, id: String) async throws
}

public enum JiraError: LocalizedError {
  case invalidResponse
  case http(Int, String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: "Nieprawidłowa odpowiedź Jiry."
    case .http(let status, let message): "Jira zwróciła HTTP \(status): \(message.prefix(300))"
    }
  }
}

public final class JiraClient: JiraAccess, @unchecked Sendable {
  private struct User: Decodable {
    let accountId: String?
    let key: String?
    let name: String?
    let displayName: String?
    var id: String { accountId ?? key ?? name ?? "" }
  }
  private struct Issue: Decodable { let key: String; let fields: Fields? }
  private struct Fields: Decodable { let summary: String? }
  private struct SearchPage: Decodable { let issues: [Issue]; let total: Int }
  private struct Worklog: Decodable {
    let id: String
    let started: String
    let timeSpentSeconds: Int
    let author: User
  }
  private struct WorklogPage: Decodable {
    let worklogs: [Worklog]
    let total: Int?
    let startAt: Int?
  }
  private struct WorklogBody: Encodable {
    let started: String
    let timeSpentSeconds: Int
    let comment: String?
  }
  private struct UserWorklog {
    let day: LocalDay
    let issue: String
    let id: String
    let seconds: Int
  }

  private let credentials: JiraCredentials
  private let session: URLSession

  public init(credentials: JiraCredentials, session: URLSession = .shared) {
    self.credentials = credentials
    self.session = session
  }

  public func currentUser() async throws -> JiraUser {
    let user: User = try await request(path: "/myself")
    guard !user.id.isEmpty else { throw JiraError.invalidResponse }
    return JiraUser(id: user.id, displayName: user.displayName ?? user.id)
  }

  public func dailyWorklogs(userID: String, from: LocalDay, to: LocalDay) async throws -> [LocalDay: DayTotal] {
    var days: [LocalDay: DayTotal] = [:]
    for worklog in try await userWorklogs(userID: userID, from: from, to: to) {
      var total = days[worklog.day, default: DayTotal()]
      total.seconds += worklog.seconds
      if !total.issueKeys.contains(worklog.issue) { total.issueKeys.append(worklog.issue) }
      total.worklogIDs.append(worklog.id)
      days[worklog.day] = total
    }
    return days
  }

  public func worklogSecondsByIssue(userID: String, on day: LocalDay) async throws -> [String: Int] {
    try await userWorklogs(userID: userID, from: day, to: day).reduce(into: [:]) {
      $0[$1.issue, default: 0] += $1.seconds
    }
  }

  private func userWorklogs(userID: String, from: LocalDay, to: LocalDay) async throws -> [UserWorklog] {
    let jql = "worklogAuthor = currentUser() AND worklogDate >= \"\(from)\" AND worklogDate <= \"\(to)\""
    var issues: [Issue] = []
    var start = 0
    repeat {
      let page: SearchPage = try await request(path: "/search", query: [
        URLQueryItem(name: "jql", value: jql), URLQueryItem(name: "fields", value: "summary"),
        URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "startAt", value: String(start)),
      ])
      issues += page.issues
      start += page.issues.count
      if page.issues.isEmpty || start >= page.total { break }
    } while true

    var result: [UserWorklog] = []
    for issue in issues {
      for worklog in try await worklogs(issue: issue.key) {
        guard worklog.author.id == userID, let day = LocalDay(String(worklog.started.prefix(10))), day >= from, day <= to else { continue }
        result.append(UserWorklog(day: day, issue: issue.key, id: worklog.id, seconds: worklog.timeSpentSeconds))
      }
    }
    return result
  }

  public func issueSummary(_ issue: String) async throws -> String {
    let value: Issue = try await request(path: "/issue/\(issue)", query: [URLQueryItem(name: "fields", value: "summary")])
    return "\(value.key) — \(value.fields?.summary ?? "")"
  }

  public func issueWorklogs(issue: String, userID: String) async throws -> [LocalDay: DayTotal] {
    var days: [LocalDay: DayTotal] = [:]
    for worklog in try await worklogs(issue: issue) {
      guard worklog.author.id == userID, let day = LocalDay(String(worklog.started.prefix(10))) else { continue }
      var total = days[day, default: DayTotal()]
      total.seconds += worklog.timeSpentSeconds
      total.worklogIDs.append(worklog.id)
      days[day] = total
    }
    return days
  }

  public func addWorklog(issue: String, day: LocalDay, seconds: Int, comment: String?) async throws {
    let body = WorklogBody(started: "\(day)T09:00:00.000+0000", timeSpentSeconds: seconds, comment: comment)
    let _: Worklog = try await request(path: "/issue/\(issue)/worklog", method: "POST", body: try JSONEncoder().encode(body))
  }

  public func deleteWorklog(issue: String, id: String) async throws {
    try await requestVoid(path: "/issue/\(issue)/worklog/\(id)", method: "DELETE")
  }

  private func worklogs(issue: String) async throws -> [Worklog] {
    var result: [Worklog] = []
    var start = 0
    repeat {
      let page: WorklogPage = try await request(path: "/issue/\(issue)/worklog", query: [
        URLQueryItem(name: "startAt", value: String(start)), URLQueryItem(name: "maxResults", value: "1000"),
      ])
      result += page.worklogs
      start = (page.startAt ?? start) + page.worklogs.count
      if page.worklogs.isEmpty || start >= (page.total ?? result.count) { return result }
    } while true
  }

  private func request<T: Decodable>(
    path: String,
    query: [URLQueryItem] = [],
    method: String = "GET",
    body: Data? = nil
  ) async throws -> T {
    let data = try await data(path: path, query: query, method: method, body: body)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func requestVoid(path: String, method: String) async throws {
    _ = try await data(path: path, method: method)
  }

  private func data(
    path: String,
    query: [URLQueryItem] = [],
    method: String = "GET",
    body: Data? = nil
  ) async throws -> Data {
    var components = URLComponents(url: credentials.url.appendingPathComponent("rest/api/2\(path)"), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.queryItems = query }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let authorization = credentials.email.isEmpty
      ? "Bearer \(credentials.token)"
      : "Basic \(Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString())"
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw JiraError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      throw JiraError.http(response.statusCode, String(decoding: data, as: UTF8.self))
    }
    return data
  }
}
