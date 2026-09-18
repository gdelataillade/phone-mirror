import AppKit
import MirrorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class RecordingController: ObservableObject {
  @Published var recording = false
  @Published var busy = false
  @Published var elapsed = 0
  @Published var notice: String?
  private var writer: VideoRecording?
  private var timer: Timer?
  private var started = 0.0
  private var destination: URL?
  private var panel: NSSavePanel?
  private var onFinished: [() -> Void] = []

  func start(model: MirrorModel) {
    guard !busy, !recording, model.canControl else { return }
    busy = true
    let attempt = model.sessionID
    let panel = NSSavePanel()
    self.panel = panel
    panel.allowedContentTypes = [.quickTimeMovie]
    panel.canCreateDirectories = true
    panel.title = "Record iPhone Screen"
    panel.message = "Silent video. Recording starts after you choose Save."
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    panel.nameFieldStringValue = "PhoneMirror \(formatter.string(from: Date())).mov"
    panel.begin { [weak self, weak model] response in
      guard let self else { return }
      self.panel = nil
      self.busy = false
      guard response == .OK, let url = panel.url, let model,
        model.sessionID == attempt, model.canControl,
        let frame = model.session?.mailbox.latest(),
        let presentation = ScreenPresentation(
          encoded: frame.size, rawOrientation: frame.orientation)
      else { return }
      do {
        // Keep an existing destination intact until the new movie has finished successfully.
        let folder = try FileManager.default.url(
          for: .itemReplacementDirectory, in: .userDomainMask,
          appropriateFor: url, create: true)
        let temporary = folder.appendingPathComponent("Recording.mov")
        self.writer = try VideoRecording(url: temporary, size: presentation.size) { [weak self] _ in
          DispatchQueue.main.async { self?.stop() }
        }
        self.destination = url
        self.started = ProcessInfo.processInfo.systemUptime
        self.elapsed = 0
        self.recording = true
        self.sample(model: model)
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
          [weak self, weak model] _ in
          Task { @MainActor in
            guard let model else {
              self?.stop()
              return
            }
            self?.sample(model: model)
          }
        }
      } catch { self.notice = error.localizedDescription }
    }
  }

  private func sample(model: MirrorModel) {
    guard recording else { return }
    guard model.connected, model.hasPicture else {
      stop()
      return
    }
    let seconds = ProcessInfo.processInfo.systemUptime - started
    elapsed = Int(seconds)
    guard let frame = model.session?.mailbox.latest(),
      let presentation = ScreenPresentation(encoded: frame.size, rawOrientation: frame.orientation)
    else { return }
    writer?.append(
      image: FrameImage.oriented(
        pixelBuffer: frame.pixelBuffer,
        quarterTurns: presentation.clockwiseQuarterTurns), seconds: seconds)
  }

  func stop(completion: (() -> Void)? = nil) {
    if let completion { onFinished.append(completion) }
    if let panel {
      panel.cancel(nil)
      self.panel = nil
      busy = false
      complete()
      return
    }
    if busy { return }
    guard let writer else {
      complete()
      return
    }
    recording = false
    busy = true
    timer?.invalidate()
    timer = nil
    self.writer = nil
    let destination = destination!
    writer.finish(seconds: ProcessInfo.processInfo.systemUptime - started) { [weak self] result in
      var message: String
      switch result {
      case .success(let url):
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: url)
          } else {
            try FileManager.default.moveItem(at: url, to: destination)
          }
          try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
          message = "Recording saved to \(destination.path)"
        } catch {
          message =
            "Could not save to the selected location: \(error.localizedDescription)\nThe finished recording is available at \(url.path)"
        }
      case .failure(let error): message = "Recording failed: \(error.localizedDescription)"
      }
      DispatchQueue.main.async {
        self?.busy = false
        self?.notice = message
        self?.complete()
      }
    }
  }

  private func complete() {
    let callbacks = onFinished
    onFinished.removeAll()
    callbacks.forEach { $0() }
  }
}

struct RecordingCommands: View {
  @ObservedObject var model: MirrorModel
  @ObservedObject var recorder: RecordingController
  var body: some View {
    Button(recorder.recording ? "Stop Recording" : "Start Recording…") {
      if recorder.recording { recorder.stop() } else { recorder.start(model: model) }
    }.keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(recorder.busy || (!recorder.recording && !model.canControl))
  }
}

struct RecordingButton: View {
  @ObservedObject var model: MirrorModel
  @ObservedObject var recorder: RecordingController
  var body: some View {
    Button {
      if recorder.recording { recorder.stop() } else { recorder.start(model: model) }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: recorder.recording ? "stop.circle.fill" : "record.circle")
          .foregroundStyle(recorder.recording ? Color.red : Color.secondary)
        if recorder.recording {
          Text(String(format: "%d:%02d", recorder.elapsed / 60, recorder.elapsed % 60))
            .font(.system(size: 10, design: .monospaced))
        }
      }
    }.buttonStyle(.borderless)
      .help(recorder.recording ? "Stop recording ⇧⌘S" : "Record iPhone screen ⇧⌘S")
      .accessibilityLabel(recorder.recording ? "Stop recording" : "Record iPhone screen")
      .disabled(recorder.busy || (!recorder.recording && !model.canControl))
      .alert(
        "Screen recording",
        isPresented: Binding(
          get: { recorder.notice != nil }, set: { if !$0 { recorder.notice = nil } }
        )
      ) {
        Button("OK", role: .cancel) { recorder.notice = nil }
      } message: {
        Text(recorder.notice ?? "")
      }
  }
}
