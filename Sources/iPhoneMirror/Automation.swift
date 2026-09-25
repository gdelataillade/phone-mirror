import AppKit
import CoreImage
import MirrorCore

extension MirrorModel {
  func setAutomationEnabled(_ enabled: Bool) {
    stopAgentAction()
    automationServer?.stop()
    automationServer = nil
    automationEnabled = enabled
    automationStatus = enabled ? "Starting agent access…" : "Agent access off"
    guard enabled else { return }
    let server = AutomationServer(port: UInt16(automationPort)) { [weak self] request in
      guard let self, self.automationEnabled else {
        throw AutomationFailure(503, "Agent access off")
      }
      return try await self.automationRequest(request)
    } state: { [weak self] status, ready in
      self?.automationStatus = status
      if !ready { self?.automationEnabled = false }
    }
    automationServer = server
    do { try server.start() } catch {
      server.stop()
      automationEnabled = false
      automationStatus = "Agent access could not start."
    }
  }

  func stopAgentAction() { releaseInputs() }

  /// Restarts a running listener so the new port takes effect immediately.
  func setAutomationPort(_ port: Int) {
    guard port != automationPort else { return }
    automationPort = port
    if automationEnabled { setAutomationEnabled(true) }
  }

  func chooseCustomAutomationPort() {
    let alert = NSAlert()
    alert.messageText = "Agent Access Port"
    alert.informativeText = "Enter a port from 1024 to 65535. Agents still need the token."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
    field.stringValue = String(
      automationPort == AutomationPort.automatic ? AutomationPort.preset : automationPort)
    alert.accessoryView = field
    alert.addButton(withTitle: "Use Port")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let port = AutomationPort.parse(field.stringValue) else {
      automationStatus = "Invalid port. Use 1024–65535."
      return
    }
    setAutomationPort(port)
  }

  private func observationID(_ id: UUID, _ frame: VideoFrame) -> String {
    "\(id.uuidString):\(frame.orientation):\(Int(frame.size.width))x\(Int(frame.size.height))"
  }

  private func automationRequest(_ request: AutomationRequest) async throws -> AutomationResponse {
    if request.method == "GET", request.path == "/v1/screenshot" {
      let options = try ScreenshotOptions(query: request.query)
      let shot = try await agentScreenshot(options)
      guard options.rawPNG else {
        var json = shot.metadata
        json["image"] = shot.png.base64EncodedString()
        json["mimeType"] = "image/png"
        return .json(json)
      }
      let headers = shot.metadata.compactMap { key, value -> (String, String)? in
        guard key != "coordinates" else { return nil }
        return ("X-iPhoneMirror-\(key.prefix(1).uppercased() + key.dropFirst())", "\(value)")
      }.sorted { $0.0 < $1.0 }
      return .binary(shot.png, contentType: "image/png", headers: headers)
    }
    try request.requireQuery(allowing: [])
    return .json(try await automationJSON(request))
  }

  private func automationJSON(_ request: AutomationRequest) async throws -> [String: Any] {
    if request.method == "GET", request.path == "/v1/status" {
      return [
        "apiVersion": 1, "connected": connected, "canControl": canControl,
        "sessionID": sessionID?.uuidString as Any? ?? NSNull(),
        "observationID": sessionID.flatMap { id in
          session?.mailbox.latest().map { observationID(id, $0) }
        } as Any? ?? NSNull(),
        "width": Int(screenSize.width), "height": Int(screenSize.height),
        "fps": fps, "busy": automationBusy, "status": status,
        "capabilities": [
          "screenshot", "tap", "swipe", "type", "key", "home", "button",
          "app_switcher", "spotlight", "control_center", "rotate", "release",
        ],
      ]
    }
    guard request.method == "POST", request.path == "/v1/actions" else {
      throw AutomationFailure(404, "Unknown endpoint")
    }
    let action = try AutomationAction(data: request.body)
    if let expected = action.sessionID, expected != sessionID?.uuidString {
      throw AutomationFailure(409, "Session changed; observe again before acting")
    }
    if action.operation == .release {
      stopAgentAction()
      return [
        "accepted": true,
        "note":
          "Active gesture cancelled; input release requested (session closes if its input queue is full)",
      ]
    }
    guard !automationBusy else { throw AutomationFailure(409, "Another agent action is running") }
    guard canControl, let native = session, let id = sessionID, let frame = native.mailbox.latest(),
      let orientation = DisplayOrientation(rawValue: frame.orientation),
      ScreenPresentation(encoded: frame.size, rawOrientation: frame.orientation) != nil
    else { throw AutomationFailure(409, "Connect and unlock an iPhone; wait for stable video") }
    if let expected = action.observationID, expected != observationID(id, frame) {
      throw AutomationFailure(409, "Screen orientation or session changed; take another screenshot")
    }
    releaseInputs()
    let epoch = inputEpoch
    automationBusy = true
    defer { automationBusy = false }
    func validate() throws {
      try Task.checkCancellation()
      guard automationEnabled, sessionID == id, inputEpoch == epoch, canControl,
        let current = native.mailbox.latest(), current.orientation == frame.orientation,
        current.size == frame.size
      else {
        throw AutomationFailure(
          409, "Action cancelled: session, orientation or input state changed")
      }
    }
    func send(_ kind: UInt32) throws {
      try validate()
      guard native.send(kind) else { throw AutomationFailure(409, "Input queue unavailable") }
    }
    switch action.operation {
    case .tap, .swipe, .key:
      try await AutomationGesture.perform(
        action, orientation: orientation, validate: validate,
        send: { native.send($0, $1, $2) })
    case .type:
      try validate()
      guard native.paste(action.text) else {
        throw AutomationFailure(409, "Paste could not be queued")
      }
    case .home: try send(5)
    case .button:
      if let id = action.button.nativeID {
        try validate()
        guard native.send(13, id) else { throw AutomationFailure(409, "Input queue unavailable") }
      } else {
        try send(5)
      }
    case .appSwitcher: try send(8)
    case .spotlight: try send(11)
    case .controlCenter: try send(12)
    case .rotate:
      try validate()
      rotate(clockwise: action.clockwise)
      guard rotation.isPending else { throw AutomationFailure(409, "Rotation could not be queued") }
    case .release: break
    }
    return [
      "accepted": true, "sessionID": id.uuidString,
      "note": "Input queued. Take another screenshot to verify the result on the phone.",
    ]
  }

  private func agentScreenshot(_ options: ScreenshotOptions) async throws
    -> (png: Data, metadata: [String: Any])
  {
    guard !automationCapturing else {
      throw AutomationFailure(429, "A screenshot is already being encoded")
    }
    guard canControl, let id = sessionID, let frame = session?.mailbox.latest(),
      let presentation = ScreenPresentation(encoded: frame.size, rawOrientation: frame.orientation)
    else { throw AutomationFailure(409, "No stable iPhone frame available") }
    automationCapturing = true
    defer { automationCapturing = false }
    let quarterTurns = presentation.clockwiseQuarterTurns
    let result: (Data, Int, Int)? = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        var image = FrameImage.oriented(
          pixelBuffer: frame.pixelBuffer,
          quarterTurns: quarterTurns)
        let scale = options.scale(for: image.extent.size)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        // Integral bounds make reported pixel dimensions exactly match the returned PNG.
        let bounds = CGRect(
          x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height))
        image = image.cropped(to: bounds)
        let png = context.pngRepresentation(
          of: image, format: .RGBA8,
          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        continuation.resume(returning: png.map { ($0, Int(bounds.width), Int(bounds.height)) })
      }
    }
    try Task.checkCancellation()
    guard automationEnabled, sessionID == id, canControl, let current = session?.mailbox.latest(),
      current.orientation == frame.orientation, current.size == frame.size
    else { throw AutomationFailure(409, "Session or orientation changed during capture") }
    guard let (data, width, height) = result else {
      throw AutomationFailure(500, "Could not encode the frame")
    }
    return (data, [
      "width": width, "height": height,
      "sessionID": id.uuidString, "frameID": String(frame.ordinal),
      "observationID": observationID(id, frame),
      "ageSeconds": ProcessInfo.processInfo.systemUptime - frame.receivedAt,
      "coordinates": "Normalized 0...1; origin at top left of this upright image",
    ])
  }
}
