import AppKit
import CoreImage
import MetalKit
import MirrorCore
import SwiftUI
import UniformTypeIdentifiers

struct MirrorSurface: NSViewRepresentable {
  @ObservedObject var model: MirrorModel
  var cornerRadius: CGFloat = 0
  /// Total space (both sides combined) the bezel currently reserves around this view.
  var bezelInset: CGFloat = 0
  func makeNSView(context: Context) -> MirrorView { MirrorView(model: model) }
  func updateNSView(_ view: MirrorView, context: Context) {
    view.cornerRadius = cornerRadius
    view.bezelInset = bezelInset
    view.synchronize(model: model)
  }
}

final class MirrorView: MTKView, MTKViewDelegate {
  var cornerRadius: CGFloat = 0
  var bezelInset: CGFloat = 0
  weak var model: MirrorModel?
  private var ci: CIContext?
  private var commands: MTLCommandQueue?
  private var presented: UInt64 = 0
  private var presentedSize = CGSize.zero
  private var presentedOrientation: UInt32 = 0
  private weak var inputSession: NativeSession?
  private let generation: UUID?
  private var fitWindowEpoch: UInt64
  private var lastLandscape: Bool?
  private var fitWork: DispatchWorkItem?
  private var inputEpoch: UInt64
  private var presentedGeometry: InputGeometry?
  private var geometryChangedAt = 0.0
  private var mouseHeld = false
  private var touchDown = false
  private var scroll = ScrollGesture()
  private var scrollEnd: DispatchWorkItem?
  private var motion: DispatchWorkItem?
  private var pendingContact: CGPoint?
  private var keyboard = KeyboardState()
  private var capsFlag = false
  private var observers: [NSObjectProtocol] = []
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(model: MirrorModel) {
    generation = model.sessionID
    fitWindowEpoch = model.fitWindowEpoch
    inputEpoch = model.inputEpoch
    inputSession = model.session
    let gpu = MTLCreateSystemDefaultDevice()
    super.init(frame: .zero, device: gpu)
    self.model = model
    if let gpu {
      ci = CIContext(mtlDevice: gpu, options: [.cacheIntermediates: false])
      commands = gpu.makeCommandQueue()
    }
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = false
    isPaused = false
    preferredFramesPerSecond = 60
    // A SwiftUI-level .onDrop here was unreliable: this AppKit view is the actual
    // frontmost view occupying this screen region, and competes with whatever
    // hidden view SwiftUI installs its own drop target on. Registering directly
    // on this view is the canonical, reliable way to receive drags.
    registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(UTType.image.identifier)])
    // Matches the bezel's own background (PhoneBezel.swift) so a sub-pixel aspect-fit
    // rounding gap at the content's edge blends in instead of showing as a seam.
    clearColor = MTLClearColorMake(0.045, 0.045, 0.045, 1)
    delegate = self
    setAccessibilityLabel("Mirrored iPhone screen")
    setAccessibilityHelp("Click to focus. Mouse and keyboard control the connected iPhone.")
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.releaseAll() })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let self, let window = notification.object as? NSWindow, window === self.window else {
          return
        }
        self.releaseAll()
      })
  }
  deinit {
    scrollEnd?.cancel()
    motion?.cancel()
    fitWork?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    releaseAll()
    presented = 0
    presentedGeometry = nil
  }
  func synchronize(model: MirrorModel) {
    self.model = model
    if model.automationBusy {
      // The agent released native input before taking the gesture. Clear local
      // repeat/drag state without releasing the agent's new contact.
      releaseAll()
      inputEpoch = model.inputEpoch
      return
    }
    if fitWindowEpoch != model.fitWindowEpoch {
      fitWindowEpoch = model.fitWindowEpoch
      scheduleWindowFit()
    }
    let current = model.session?.mailbox.latest().flatMap {
      InputGeometry(view: bounds.size, screen: $0.size, rawOrientation: $0.orientation)
    }
    if inputEpoch != model.inputEpoch || !model.canControl || model.sessionID != generation
      || current != presentedGeometry
    {
      if touchDown || !keyboard.isEmpty { releaseAll() }
      inputEpoch = model.inputEpoch
    }
  }
  func draw(in view: MTKView) {
    guard let model, model.hasPicture, let frame = model.session?.mailbox.latest(),
      frame.ordinal != presented || drawableSize != presentedSize,
      let drawable = currentDrawable, let buffer = commands?.makeCommandBuffer(), let ci
    else { return }
    let presentation = ScreenPresentation(encoded: frame.size, rawOrientation: frame.orientation)
    let screen = presentation?.size ?? frame.size
    let landscape = screen.width > screen.height
    if lastLandscape != landscape && (lastLandscape != nil || landscape) { scheduleWindowFit() }
    lastLandscape = landscape
    let geometry = InputGeometry(
      view: bounds.size, screen: frame.size, rawOrientation: frame.orientation)
    if geometry != presentedGeometry || frame.orientation != presentedOrientation {
      releaseAll()
      presentedOrientation = frame.orientation
      geometryChangedAt = ProcessInfo.processInfo.systemUptime
    }
    let rect = MirrorGeometry.contentRect(view: drawableSize, screen: screen)
    var image = FrameImage.oriented(
      pixelBuffer: frame.pixelBuffer, quarterTurns: presentation?.clockwiseQuarterTurns ?? 0)
    let scale = min(rect.width / image.extent.width, rect.height / image.extent.height)
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(
      by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    let bounds = CGRect(origin: .zero, size: drawableSize)
    // Matches the bezel's own background (PhoneBezel.swift) — see clearColor above.
    let background = CIImage(color: CIColor(red: 0.045, green: 0.045, blue: 0.045)).cropped(
      to: bounds)
    ci.render(
      image.composited(over: background), to: drawable.texture, commandBuffer: buffer,
      bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    buffer.present(drawable)
    buffer.commit()
    presentedGeometry = geometry
    presented = frame.ordinal
    presentedSize = drawableSize
  }
  private func scheduleWindowFit() {
    fitWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let window = self.window, let frame = self.inputSession?.mailbox.latest(),
        self.model?.sessionID == self.generation,
        let presentation = ScreenPresentation(
          encoded: frame.size, rawOrientation: frame.orientation)
      else { return }
      self.releaseAll()
      let visible = window.screen?.visibleFrame.size ?? CGSize(width: 1200, height: 900)
      // Anchor on the window's own current content size, not this view's bounds: with the
      // bezel on, this view is already an aspect-fitted rect inset within that content size,
      // so it understates how much room the window actually has to work with.
      let currentContent = window.contentView?.bounds.size ?? bounds.size
      let inset = bezelInset
      let aspect = presentation.size.width / presentation.size.height
      let longSide = max(1, max(currentContent.width, currentContent.height) - inset)
      var height = aspect > 1 ? longSide / aspect : longSide
      var width = height * aspect
      let scale = min(
        1, (visible.width - 40 - inset) / width, (visible.height - 40 - inset) / height)
      width *= scale
      height *= scale
      window.setContentSize(
        CGSize(
          width: max(360, width + inset),
          height: max(aspect > 1 ? 360 : 580, height + inset)))
    }
    fitWork = work
    // Give SwiftUI time to apply the landscape minimum window size first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }
  private var activeGeometry: InputGeometry? {
    guard let model, !model.automationBusy, model.sessionID == generation, model.canControl,
      let frame = inputSession?.mailbox.latest(),
      let geometry = InputGeometry(
        view: bounds.size, screen: frame.size, rawOrientation: frame.orientation),
      geometry == presentedGeometry,
      ProcessInfo.processInfo.systemUptime - geometryChangedAt >= 0.15
    else { return nil }
    return geometry
  }
  private func contact(_ point: CGPoint, clamp: Bool = false) {
    guard let geometry = activeGeometry, let (x, y) = geometry.point(point, clamp: clamp) else {
      return
    }
    if !touchDown {
      touchDown = inputSession?.send(1, x, y) == true
      return
    }
    pendingContact = point
    if motion == nil {
      let update = DispatchWorkItem { [weak self] in self?.flushMotion() }
      motion = update
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: update)
    }
  }
  private func flushMotion() {
    motion?.cancel()
    motion = nil
    guard let point = pendingContact else { return }
    pendingContact = nil
    guard touchDown, let geometry = activeGeometry, let (x, y) = geometry.point(point, clamp: true)
    else {
      releaseAll()
      return
    }
    _ = inputSession?.send(1, x, y)
  }
  private func endTouch() {
    // A mouse-up or scheduled scroll-end can arrive before SwiftUI synchronizes
    // the new agent ownership. Discard that stale local gesture without lifting
    // the agent's contact; releaseAll suppresses native release while it is busy.
    if model?.automationBusy == true {
      releaseAll()
      return
    }
    flushMotion()
    if touchDown { _ = inputSession?.send(2) }
    touchDown = false
  }
  override func mouseDown(with event: NSEvent) {
    synchronizeIfNeeded()
    let point = convert(event.locationInWindow, from: nil)
    guard activeGeometry?.point(point) != nil,
      cornerRadius == 0
        || NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).contains(
          point)
    else { return }
    window?.makeFirstResponder(self)
    endScroll()
    mouseHeld = true
    contact(point)
  }
  override func mouseDragged(with event: NSEvent) {
    synchronizeIfNeeded()
    if mouseHeld { contact(convert(event.locationInWindow, from: nil), clamp: true) }
  }
  override func mouseUp(with event: NSEvent) {
    if mouseHeld {
      endTouch()
      mouseHeld = false
    }
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let canControl = model?.canControl == true
    if ProcessInfo.processInfo.environment["PM_TRACE"] != nil {
      traceLog("drop: draggingEntered canControl=\(canControl) types=\(sender.draggingPasteboard.types ?? [])")
    }
    return canControl ? .copy : []
  }
  // Tries a dropped Finder file first (the stated use case), then falls back to
  // raw image data for a drag that isn't file-backed (e.g. from a webpage or
  // Preview). NSPasteboard reads are synchronous, unlike NSItemProvider's
  // completion-handler API, so this needs no dispatching back to the main
  // thread — performDragOperation is already called on it.
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let trace = ProcessInfo.processInfo.environment["PM_TRACE"] != nil
    let pasteboard = sender.draggingPasteboard
    let image: NSImage?
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
      let url = urls.first
    {
      if trace { traceLog("drop: file URL \(url)") }
      image = NSImage(contentsOf: url)
    } else if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)
      as? [NSImage]
    {
      if trace { traceLog("drop: raw image data, \(images.count) image(s) on pasteboard") }
      image = images.first
    } else {
      if trace { traceLog("drop: no URL or image found; types=\(pasteboard.types ?? [])") }
      image = nil
    }
    guard let image, let (data, format) = MirrorView.encodedImageData(from: image) else {
      if trace { traceLog("drop: failed to load or encode an image") }
      NSSound.beep()
      return false
    }
    if trace { traceLog("drop: pasting \(data.count) \(format) bytes") }
    let ok = model?.pasteImage(data, format: format) == true
    if trace { traceLog("drop: pasteImage returned \(ok)") }
    return ok
  }
  // Re-encodes to a well-formed PNG or JPEG regardless of source format, so the
  // native layer only ever has to handle two known encodings. PNG (lossless) is
  // preferred, but a real ~1.3MB PNG photo reliably failed to paste at all while
  // 420KB worked — confirmed live, with the transport layer itself ruled out as
  // the cause (see VALIDATION.md) — so anything bigger downscales and re-encodes
  // as JPEG instead. Downscaling matters, not just switching format: a full-
  // resolution 3024×4032 iPhone photo is still ~1MB+ as JPEG even at 0.85
  // quality — bigger than the confirmed-failing size — while capping the long
  // edge at 1600px lands comfortably under the confirmed-working size with
  // real margin, and iMessage's own default photo sharing already downscales
  // similarly, so this isn't a quality regression for the stated use case.
  private static let jpegFallbackThreshold = 500_000
  private static let jpegMaxDimension: CGFloat = 1600
  private static func encodedImageData(from image: NSImage) -> (Data, ImageFormat)? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
      return nil
    }
    if let png = rep.representation(using: .png, properties: [:]),
      png.count <= jpegFallbackThreshold
    {
      return (png, .png)
    }
    let source = image.size
    let scale = min(1, jpegMaxDimension / max(source.width, source.height))
    let target = NSSize(width: source.width * scale, height: source.height * scale)
    let resized = NSImage(size: target)
    resized.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: source),
      operation: .copy, fraction: 1)
    resized.unlockFocus()
    guard let resizedTiff = resized.tiffRepresentation,
      let resizedRep = NSBitmapImageRep(data: resizedTiff),
      let jpeg = resizedRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    else { return nil }
    return (jpeg, .jpeg)
  }
  override func scrollWheel(with event: NSEvent) {
    synchronizeIfNeeded()
    // iOS supplies inertia after touch-up; replaying Mac momentum would apply it twice.
    guard event.momentumPhase.isEmpty else { return }
    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      endScroll()
      return
    }
    guard !mouseHeld, let geometry = activeGeometry else { return }
    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
    let changes = scroll.move(
      at: convert(event.locationInWindow, from: nil),
      delta: CGSize(
        width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier),
      within: geometry.contentRect)
    for change in changes {
      switch change {
      case .contact(let point): contact(point, clamp: true)
      case .release: endTouch()
      }
    }
    scrollEnd?.cancel()
    let end = DispatchWorkItem { [weak self] in self?.endScroll() }
    scrollEnd = end
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: end)
  }
  private func endScroll() {
    scrollEnd?.cancel()
    scrollEnd = nil
    if !scroll.end().isEmpty { endTouch() }
  }
  private func synchronizeIfNeeded() { if let model { synchronize(model: model) } }
  private func send(_ transitions: [KeyTransition]) {
    for change in transitions { _ = inputSession?.send(change.down ? 3 : 4, change.usage) }
  }
  private func isMacShortcut(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
      .capsLock, .numericPad, .function,
    ])
    guard flags.contains(.command) else { return false }
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if ["q", "w", "h", "m"].contains(key) { return true }
    if flags == .command && ["v", "r", "0", "s", "1", "2", "3", "4"].contains(key) { return true }
    if flags == [.command, .shift] && ["a", "h", "d", "r", "c", "s"].contains(key) { return true }
    if flags == [.command, .option]
      && (["t", "b"].contains(key) || [123, 124].contains(event.keyCode))
    {
      return true
    }
    return event.keyCode == 53  // Command–Escape releases all inputs.
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
    if isMacShortcut(event) {
      releaseAll()
      return false
    }
    guard event.modifierFlags.contains(.command), activeGeometry != nil,
      KeyboardMap.usages[event.keyCode] != nil
    else { return super.performKeyEquivalent(with: event) }
    keyDown(with: event)
    return true
  }
  override func keyDown(with event: NSEvent) {
    synchronizeIfNeeded()
    if isMacShortcut(event) {
      releaseAll()
      super.keyDown(with: event)
      return
    }
    guard activeGeometry != nil, let usage = KeyboardMap.usages[event.keyCode] else { return }
    send(
      keyboard.keyDown(
        usage, modifiers: ModifierKeys.usages(rawFlags: UInt64(event.modifierFlags.rawValue)),
        repeating: event.isARepeat))
  }
  override func keyUp(with event: NSEvent) {
    guard model?.automationBusy != true else { return }
    if let usage = KeyboardMap.usages[event.keyCode] { send(keyboard.keyUp(usage)) }
  }
  override func flagsChanged(with event: NSEvent) {
    synchronizeIfNeeded()
    let caps = event.modifierFlags.contains(.capsLock)
    defer { capsFlag = caps }
    guard activeGeometry != nil else { return }
    // Defer new modifier presses until a remote key is sent, preserving local shortcuts.
    send(
      keyboard.modifiersChanged(ModifierKeys.usages(rawFlags: UInt64(event.modifierFlags.rawValue)))
    )
    if event.keyCode == 57 && caps != capsFlag {
      _ = inputSession?.send(3, 57)
      _ = inputSession?.send(4, 57)
    }
  }
  override func becomeFirstResponder() -> Bool {
    capsFlag = NSEvent.modifierFlags.contains(.capsLock)
    return super.becomeFirstResponder()
  }
  override func resignFirstResponder() -> Bool {
    releaseAll()
    return super.resignFirstResponder()
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { releaseAll() }
    super.viewWillMove(toWindow: newWindow)
  }
  private func releaseAll() {
    scrollEnd?.cancel()
    scrollEnd = nil
    motion?.cancel()
    motion = nil
    pendingContact = nil
    _ = scroll.end()
    mouseHeld = false
    touchDown = false
    _ = keyboard.releaseAll()
    if model?.automationBusy != true { _ = inputSession?.send(6) }
  }
}
