import AppKit
import MirrorCore
import UniformTypeIdentifiers

extension MirrorModel {
  var canCaptureScreenshot: Bool {
    guard !screenshotBusy, canControl, let frame = session?.mailbox.latest() else { return false }
    return ScreenPresentation(encoded: frame.size, rawOrientation: frame.orientation) != nil
  }

  func saveScreenshot() { captureScreenshot(copy: false) }
  func copyScreenshot() { captureScreenshot(copy: true) }

  private func captureScreenshot(copy: Bool) {
    guard canCaptureScreenshot, let frame = session?.mailbox.latest() else { return }
    // Retain this buffer before opening a panel; later frames cannot change the capture.
    let capturedAt = Date()
    screenshotBusy = true
    screenshotNotice = nil
    releaseInputs()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let data = FrameImage.png(
        pixelBuffer: frame.pixelBuffer, encoded: frame.size, rawOrientation: frame.orientation)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard let data else {
          self.screenshotBusy = false
          self.screenshotError =
            "The current iPhone picture could not be encoded. Try again once the picture is stable."
          return
        }
        if copy {
          NSPasteboard.general.clearContents()
          if NSPasteboard.general.setData(data, forType: .png) {
            self.showScreenshotNotice("Screenshot copied")
          } else {
            self.screenshotError = "The screenshot could not be copied to the Mac clipboard."
          }
          self.screenshotBusy = false
        } else {
          self.saveScreenshotData(data, capturedAt: capturedAt)
        }
      }
    }
  }

  private func saveScreenshotData(_ data: Data, capturedAt: Date) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    panel.nameFieldStringValue = "iPhoneMirror \(formatter.string(from: capturedAt)).png"
    panel.begin { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else {
        self.screenshotBusy = false
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result { try data.write(to: url, options: .atomic) }
        DispatchQueue.main.async {
          self.screenshotBusy = false
          switch result {
          case .success: self.showScreenshotNotice("Screenshot saved")
          case .failure(let error): self.screenshotError = error.localizedDescription
          }
        }
      }
    }
  }

  private func showScreenshotNotice(_ notice: String) {
    screenshotNotice = notice
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      if self?.screenshotNotice == notice { self?.screenshotNotice = nil }
    }
  }
}
