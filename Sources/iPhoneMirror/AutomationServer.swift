import Foundation
import MirrorCore
import Network

enum AutomationResponse {
  case json([String: Any])
  /// A binary body; metadata travels in X-iPhoneMirror-* headers.
  case binary(Data, contentType: String, headers: [(String, String)])
}

/// Loopback only, opt-in for this launch, and authenticated even for screenshots.
@MainActor final class AutomationServer {
  typealias Handler = (AutomationRequest) async throws -> AutomationResponse
  static var discoveryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/iPhoneMirror/automation.json")
  }
  private var listener: NWListener?
  private var peers: [UUID: AutomationPeer] = [:]
  private let token = UUID().uuidString + UUID().uuidString
  private var port: UInt16 = 0
  private let requestedPort: UInt16
  private let handler: Handler
  private let state: (String, Bool) -> Void
  /// requestedPort 0 lets the system pick a free port.
  init(
    port requestedPort: UInt16 = 0, handler: @escaping Handler,
    state: @escaping (String, Bool) -> Void
  ) {
    self.requestedPort = requestedPort
    self.handler = handler
    self.state = state
  }
  func start() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] update in
      Task { @MainActor in
        guard let self, self.listener != nil else { return }
        switch update {
        case .ready:
          guard let port = self.listener?.port?.rawValue else { return }
          self.port = port
          do {
            try self.writeDiscovery()
            self.state("Agent access on · 127.0.0.1:\(port)", true)
          } catch {
            self.stop()
            self.state("Agent access could not save its local connection file.", false)
          }
        // A taken fixed port can report waiting rather than failed; scripts expect
        // that exact port, so never fall back to another one.
        case .failed(let error), .waiting(let error):
          self.stop()
          if case .posix(.EADDRINUSE) = error {
            self.state("Port \(self.requestedPort) is already in use.", false)
          } else {
            self.state("Agent access could not start its local listener.", false)
          }
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self, self.listener != nil, self.peers.count < 8 else {
          connection.cancel()
          return
        }
        let id = UUID()
        let peer = AutomationPeer(connection: connection) { [weak self] request in
          guard let self, self.listener != nil else {
            throw AutomationFailure(503, "Agent access stopped")
          }
          try request.authorize(token: self.token, port: self.port)
          return try await self.handler(request)
        } finished: { [weak self] in
          self?.peers.removeValue(forKey: id)
        }
        self.peers[id] = peer
        peer.start()
      }
    }
    listener.start(queue: .main)
  }
  func stop() {
    listener?.cancel()
    listener = nil
    let current = Array(peers.values)
    peers.removeAll()
    for peer in current { peer.stop() }
    // A second app instance may own a newer connection file.
    if let data = try? Data(contentsOf: Self.discoveryURL),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      json["token"] == token
    {
      try? FileManager.default.removeItem(at: Self.discoveryURL)
    }
  }
  private func writeDiscovery() throws {
    let url = Self.discoveryURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONSerialization.data(withJSONObject: [
      "url": "http://127.0.0.1:\(port)", "token": token,
    ])
    // The temporary file and replacement both have owner-only permissions.
    let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: data,
        attributes: [.posixPermissions: 0o600])
    else {
      throw AutomationFailure(500, "Cannot save connection file")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    if rename(temporary.path, url.path) != 0 {
      throw AutomationFailure(500, "Cannot replace connection file")
    }
  }
}

@MainActor private final class AutomationPeer {
  private let connection: NWConnection
  private let handler: AutomationServer.Handler
  private let finished: () -> Void
  private var data = Data()
  private var done = false
  private var deadline: DispatchWorkItem?
  private var operation: Task<Void, Never>?
  init(
    connection: NWConnection, handler: @escaping AutomationServer.Handler,
    finished: @escaping () -> Void
  ) {
    self.connection = connection
    self.handler = handler
    self.finished = finished
  }
  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state { Task { @MainActor in self?.stop() } }
    }
    connection.start(queue: .main)
    let timeout = DispatchWorkItem { [weak self] in self?.stop() }
    deadline = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    receive()
  }
  func stop() {
    guard !done else { return }
    done = true
    deadline?.cancel()
    operation?.cancel()
    connection.cancel()
    finished()
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] chunk, _, complete, error in
      Task { @MainActor in
        guard let self, !self.done else { return }
        if let chunk { self.data.append(chunk) }
        do {
          if let request = try AutomationRequest.parse(self.data) {
            self.operation = Task { @MainActor [weak self] in
              guard let self else { return }
              do { self.respond(200, try await self.handler(request)) } catch let failure
                as AutomationFailure
              {
                self.respond(failure.status, ["error": failure.message])
              } catch is CancellationError {
                self.respond(409, ["error": "Action cancelled"])
              } catch { self.respond(500, ["error": "Request failed"]) }
            }
          } else if complete || error != nil {
            self.stop()
          } else {
            self.receive()
          }
        } catch let failure as AutomationFailure {
          self.respond(failure.status, ["error": failure.message])
        } catch { self.respond(400, ["error": "Invalid HTTP request"]) }
      }
    }
  }
  private func respond(_ status: Int, _ object: [String: Any]) {
    respond(status, .json(object))
  }
  private func respond(_ status: Int, _ result: AutomationResponse) {
    guard !done else { return }
    var response: Data
    switch result {
    case .json(let object):
      guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      else { return }
      response = AutomationResponseHead.make(
        status: status, contentType: "application/json", length: body.count)
      response.append(body)
    case .binary(let body, let contentType, let headers):
      response = AutomationResponseHead.make(
        status: status, contentType: contentType, length: body.count, extra: headers)
      response.append(body)
    }
    connection.send(
      content: response,
      completion: .contentProcessed { [weak self] _ in
        Task { @MainActor in self?.stop() }
      })
  }
}
