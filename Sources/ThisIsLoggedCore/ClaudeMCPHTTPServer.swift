import Foundation
import Network
import Darwin

public final class ClaudeMCPHTTPServer: @unchecked Sendable {
  public static let shared = ClaudeMCPHTTPServer()
  public static let defaultHeadersFile = SettingsStore.defaultDirectory.appendingPathComponent("mcp-headers.json")
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "this-is-logged.mcp")
  private let server: ClaudeMCPServer
  private let port: UInt16
  private let headersFile: URL
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]

  public init(store: ActivityStore = ActivityStore(), port: UInt16 = 43819, headersFile: URL = ClaudeMCPHTTPServer.defaultHeadersFile) {
    self.server = ClaudeMCPServer(store: store)
    self.port = port
    self.headersFile = headersFile
  }

  @discardableResult
  public func start() throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    if let listener, let port = listener.port { return URL(string: "http://127.0.0.1:\(port.rawValue)/mcp")! }
    let authorization = try authorizationHeader()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    let candidate = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    candidate.stateUpdateHandler = { state in
      switch state {
      case .ready, .failed, .cancelled: ready.signal()
      default: break
      }
    }
    candidate.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, authorization: authorization)
    }
    candidate.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, case .ready = candidate.state,
          let actualPort = candidate.port else {
      candidate.cancel()
      throw NSError(domain: "ThisIsLogged.MCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nie udało się uruchomić lokalnego serwera MCP."])
    }
    listener = candidate
    return URL(string: "http://127.0.0.1:\(actualPort.rawValue)/mcp")!
  }

  public func stop() {
    lock.lock()
    defer { lock.unlock() }
    listener?.cancel()
    listener = nil
    connections.values.forEach { $0.cancel() }
    connections.removeAll()
  }

  private func accept(_ connection: NWConnection, authorization: String) {
    lock.lock()
    defer { lock.unlock() }
    guard listener != nil else { connection.cancel(); return }
    let id = UUID()
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .cancelled, .failed:
        guard let self else { return }
        self.lock.lock()
        self.connections.removeValue(forKey: id)
        self.lock.unlock()
      default: break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    Self.receive(connection, buffer: Data(), authorization: authorization, server: server)
  }

  private func authorizationHeader() throws -> String {
    if FileManager.default.fileExists(atPath: headersFile.path) {
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: headersFile)) as? [String: String]
      guard let header = object?["Authorization"], header.hasPrefix("Bearer "), header.count > 30 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: headersFile.path)
      return header
    }
    try FileManager.default.createDirectory(at: headersFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let header = "Bearer \(UUID().uuidString)\(UUID().uuidString)"
    let data = try JSONSerialization.data(withJSONObject: ["Authorization": header])
    let descriptor = Darwin.open(headersFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try file.write(contentsOf: data)
      try file.close()
    } catch {
      try? FileManager.default.removeItem(at: headersFile)
      throw error
    }
    return header
  }

  private static func receive(_ connection: NWConnection, buffer: Data, authorization: String, server: ClaudeMCPServer) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
      var buffer = buffer
      if let data { buffer.append(data) }
      guard buffer.count <= 1024 * 1024 + 16 * 1024 else { return reply(connection, status: 413) }
      guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        guard buffer.count <= 16 * 1024 else { return reply(connection, status: 431) }
        if !complete && error == nil { receive(connection, buffer: buffer, authorization: authorization, server: server) }
        else { connection.cancel() }
        return
      }
      guard separator.lowerBound <= 16 * 1024,
            let head = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { return reply(connection, status: 400) }
      let lines = head.components(separatedBy: "\r\n")
      let requestLine = lines[0].split(separator: " ")
      guard requestLine.count == 3, requestLine[1] == "/mcp", requestLine[2] == "HTTP/1.1" else { return reply(connection, status: 404) }
      var headers: [String: String] = [:]
      for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { return reply(connection, status: 400) }
        let name = line[..<colon].lowercased()
        guard !name.isEmpty, headers[name] == nil else { return reply(connection, status: 400) }
        headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
      let authority = "127.0.0.1:\(connection.currentPath?.localEndpoint?.portNumber ?? 0)"
      guard headers["host"] == authority,
            headers["origin"] == nil || headers["origin"] == "http://\(authority)" else { return reply(connection, status: 403) }
      guard headers["authorization"] == authorization else { return reply(connection, status: 401) }
      guard requestLine[0] == "POST" else { return reply(connection, status: 405) }
      guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
            headers["transfer-encoding"] == nil,
            let lengthText = headers["content-length"], !lengthText.isEmpty,
            lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
            let length = Int(lengthText), length <= 1024 * 1024 else { return reply(connection, status: 400) }
      let end = separator.upperBound + length
      guard buffer.count >= end else {
        if !complete && error == nil { receive(connection, buffer: buffer, authorization: authorization, server: server) }
        else { reply(connection, status: 400) }
        return
      }
      guard let request = try? JSONSerialization.jsonObject(with: buffer[separator.upperBound..<end]) as? [String: Any],
            request["jsonrpc"] as? String == "2.0", request["method"] is String else { return reply(connection, status: 400) }
      if let version = headers["mcp-protocol-version"], !["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version) {
        return reply(connection, status: 400)
      }
      guard let response = server.response(to: request) else { return reply(connection, status: 202) }
      guard let body = try? JSONSerialization.data(withJSONObject: response) else { return reply(connection, status: 500) }
      reply(connection, status: 200, body: body)
    }
  }

  private static func reply(_ connection: NWConnection, status: Int, body: Data = Data()) {
    let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large", 431: "Request Header Fields Too Large", 500: "Internal Server Error"][status]!
    let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAllow: POST\r\n\r\n"
    connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}

private extension NWEndpoint {
  var portNumber: UInt16? {
    if case let .hostPort(_, port) = self { return port.rawValue }
    return nil
  }
}
