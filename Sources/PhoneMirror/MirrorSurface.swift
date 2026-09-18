import AppKit
import CoreImage
import MetalKit
import MirrorCore
import SwiftUI

struct MirrorSurface: NSViewRepresentable {
  @ObservedObject var model: MirrorModel
  var cornerRadius: CGFloat = 0
  func makeNSView(context: Context) -> MirrorView { MirrorView(model: model) }
  func updateNSView(_ view: MirrorView, context: Context) {
    view.cornerRadius = cornerRadius
    view.synchronize(model: model)
  }
}

final class MirrorView: MTKView, MTKViewDelegate {
  var cornerRadius: CGFloat = 0
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
    clearColor = MTLClearColorMake(0.035, 0.04, 0.045, 1)
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
    let background = CIImage(color: CIColor(red: 0.035, green: 0.04, blue: 0.045)).cropped(
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
      let chrome = max(
        0, (window.contentView?.bounds.height ?? self.bounds.height) - self.bounds.height)
      let aspect = presentation.size.width / presentation.size.height
      let longSide = max(self.bounds.width, self.bounds.height)
      var height = aspect > 1 ? longSide / aspect : longSide
      let horizontalChrome = max(
        0, (window.contentView?.bounds.width ?? self.bounds.width) - self.bounds.width)
      var width = height * aspect
      let scale = min(
        1, (visible.width - 40 - horizontalChrome) / width, (visible.height - 40 - chrome) / height)
      width *= scale
      height *= scale
      window.setContentSize(
        CGSize(
          width: max(360, width + horizontalChrome),
          height: max(aspect > 1 ? 360 : 580, height + chrome)))
    }
    fitWork = work
    // Give SwiftUI time to apply the landscape minimum window size first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }
  private var activeGeometry: InputGeometry? {
    guard let model, model.sessionID == generation, model.canControl,
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
    if flags == .command && ["v", "r", "0", "s"].contains(key) { return true }
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
    _ = inputSession?.send(6)
  }
}
