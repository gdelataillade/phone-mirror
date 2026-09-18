import AppKit
import Foundation
import MirrorCore

/// Exercises the actual app coordinator against a physical USB device without sending input.
@main struct ConnectionProbe {
  @MainActor static func main() async {
    if let index = CommandLine.arguments.firstIndex(of: "--seconds") {
      guard CommandLine.arguments.indices.contains(index + 1),
        let seconds = Double(CommandLine.arguments[index + 1]), seconds.isFinite,
        (10...1800).contains(seconds)
      else {
        print("Use --seconds 10...1800 for a read-only stability run")
        exit(2)
      }
      await soak(seconds: seconds)
      return
    }
    let manualReconnect = CommandLine.arguments.contains("--manual-reconnect")
    let simulateBackpressure = CommandLine.arguments.contains("--video-stall")
    var attempts = 0
    let model = MirrorModel {
      attempts += 1
      guard simulateBackpressure, attempts == 1 else { return NativeSession() }
      var frames = 0  // Used only by this session's serial decoder queue.
      return NativeSession {
        frames += 1
        if frames == 240 {
          print("Injecting one-second decoder pause to overflow the bounded queue")
          fflush(stdout)
          Thread.sleep(forTimeInterval: 1)
        }
      }
    }
    model.refresh()
    let discoveryDeadline = ProcessInfo.processInfo.systemUptime + 45
    while model.discovering && ProcessInfo.processInfo.systemUptime < discoveryDeadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard !model.selection.isEmpty else {
      print("No USB iPhone available")
      exit(2)
    }
    model.connect()
    var lastPhase: ConnectionLifecycle.Phase?
    var firstAttempt: UUID?
    var firstLive: TimeInterval?
    var secondLive: TimeInterval?
    var injected = false
    var stopped = false
    var stopTime: TimeInterval?
    var passed = false
    var interruptedAt: TimeInterval?
    let start = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - start < 75 {
      model.updateVideoState()
      let now = ProcessInfo.processInfo.systemUptime
      if model.lifecycle.phase != lastPhase {
        print("elapsed=\(Int(now - start))s phase=\(model.lifecycle.phase) status=\(model.status)")
        fflush(stdout)
        lastPhase = model.lifecycle.phase
      }
      if model.hasPicture && !injected {
        if firstLive == nil {
          firstLive = now
          firstAttempt = model.sessionID
        }
        if simulateBackpressure {
          injected = true
        } else if now - firstLive! >= 5 {
          interruptedAt = now
          if manualReconnect {
            print("Requesting manual reconnect while live")
            model.reconnectNow()
          } else {
            print("Injecting native session cancellation; user connection intent remains active")
            model.session?.cancel()
          }
          injected = true
        }
      }
      if injected && model.hasPicture && model.sessionID != firstAttempt {
        if secondLive == nil {
          secondLive = now
          if let interruptedAt {
            print("Resumed after \(String(format: "%.3f", now - interruptedAt))s")
          }
        }
        if now - secondLive! >= 5 && !stopped {
          // Force another interruption, then use Stop while the retry is pending.
          print("Interrupting again to check Stop during backoff")
          model.session?.cancel()
          stopped = true
        }
      }
      if stopped && stopTime == nil && model.lifecycle.phase == .waiting {
        model.disconnect()
        stopTime = now
        print("Stopped automatic reconnection")
      }
      if let stopTime, now - stopTime >= 12 {
        passed = !model.active && model.session == nil && model.lifecycle.phase == .idle
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    model.disconnect()
    let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 20
    while model.session != nil && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    print(
      "Finished: automaticReconnect=\(secondLive != nil) stoppedRetries=\(passed) cleanedUp=\(model.session == nil)"
    )
    print(model.diagnosticReport)
    exit(passed && secondLive != nil && model.session == nil ? 0 : 1)
  }

  @MainActor static func soak(seconds: Double) async {
    let model = MirrorModel()
    model.refresh()
    let deadline = ProcessInfo.processInfo.systemUptime + 45
    while model.discovering && ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard !model.selection.isEmpty else {
      print("No USB iPhone available")
      exit(2)
    }
    model.connect()
    let began = ProcessInfo.processInfo.systemUptime
    var lastReport = began - 10
    var sawPicture = false
    var healthyAtEnd = false
    var lastAttemptCount = 0
    while ProcessInfo.processInfo.systemUptime - began < seconds {
      model.updateVideoState()
      let now = ProcessInfo.processInfo.systemUptime
      sawPicture = sawPicture || model.hasPicture
      healthyAtEnd = model.hasPicture
      if model.diagnostics.attempts != lastAttemptCount {
        if lastAttemptCount > 0 {
          print(model.diagnostics.lastSession.report)
          fflush(stdout)
        }
        lastAttemptCount = model.diagnostics.attempts
      }
      if now - lastReport >= 10 {
        let health = model.diagnosticHealth
        print(
          "elapsed=\(Int(now - began))s phase=\(model.lifecycle.phase) attempts=\(model.diagnostics.attempts) decoded=\(health.decodedFrames) discontinuities=\(health.native.discontinuities) overflows=\(health.native.queueOverflows) orientationMax=\(health.native.orientationMaxMs)ms"
        )
        fflush(stdout)
        lastReport = now
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let health = model.diagnosticHealth
    let uninterrupted =
      sawPicture && healthyAtEnd && model.diagnostics.attempts == 1
      && health.decoderErrors == 0 && health.native.queueOverflows == 0
    model.disconnect()
    let cleanup = ProcessInfo.processInfo.systemUptime + 20
    while model.session != nil && ProcessInfo.processInfo.systemUptime < cleanup {
      try? await Task.sleep(for: .milliseconds(100))
    }
    print(model.diagnosticReport)
    print("Finished: uninterrupted=\(uninterrupted) cleanedUp=\(model.session == nil)")
    exit(uninterrupted && model.session == nil ? 0 : 1)
  }
}
