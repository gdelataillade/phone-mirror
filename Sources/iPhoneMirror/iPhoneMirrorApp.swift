import AppKit
import MirrorCore
import SwiftUI

@main struct iPhoneMirrorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = MirrorModel()
  @StateObject private var updater = Updater()
  @AppStorage("alwaysOnTop") private var alwaysOnTop = false
  @AppStorage("showDeviceBezel") private var showDeviceBezel = true
  private var customPortTitle: String {
    [AutomationPort.automatic, AutomationPort.preset].contains(model.automationPort)
      ? "Custom…" : "Custom (\(model.automationPort))…"
  }
  private static let volumeLevels = [0.25, 0.5, 0.75, 1.0]
  /// Checks the level nearest to the stored volume, which may predate these fixed levels.
  private var volumeLevel: Binding<Double> {
    Binding(
      get: {
        Self.volumeLevels.min { abs($0 - model.audioVolume) < abs($1 - model.audioVolume) } ?? 1
      },
      set: { model.audioVolume = $0 })
  }
  var body: some Scene {
    Window("iPhoneMirror", id: "mirror") {
      MirrorWindow(model: model, recorder: model.recording)
        .frame(minWidth: 360, minHeight: model.isLandscape ? 360 : 580)
        .containerBackground(.clear, for: .window)
        .onAppear {
          appDelegate.model = model
          model.refresh()
          NSApp.setActivationPolicy(.regular)
          NSApp.activate(ignoringOtherApps: true)
        }
    }
    .windowStyle(.hiddenTitleBar)
    // Fits a bezeled portrait iPhone below the title bar without side gaps.
    .defaultSize(width: 376, height: 820)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updater.checkForUpdates() }
          .disabled(!updater.canCheckForUpdates)
      }
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .pasteboard) {
        Button("Paste Text to iPhone") { model.pasteText() }.keyboardShortcut("v").disabled(
          !model.canControl)
      }
      CommandGroup(after: .windowArrangement) {
        Toggle("Always on Top", isOn: $alwaysOnTop)
          .keyboardShortcut("t", modifiers: [.command, .option])
      }
      CommandGroup(after: .toolbar) {
        Toggle("Show iPhone Bezel", isOn: $showDeviceBezel)
          .keyboardShortcut("b", modifiers: [.command, .option])
      }
      CommandMenu("iPhone") {
        Button("Save Screenshot…") { model.saveScreenshot() }.keyboardShortcut("s")
          .disabled(!model.canCaptureScreenshot)
        Button("Copy Screenshot") { model.copyScreenshot() }
          .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(
            !model.canCaptureScreenshot)
        RecordingCommands(model: model, recorder: model.recording)
        Toggle("Mute iPhone Audio", isOn: $model.audioMuted)
          .keyboardShortcut("m", modifiers: [.command, .option])
        Picker("Volume", selection: volumeLevel) {
          ForEach(Self.volumeLevels, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
        }.disabled(model.audioMuted)
        Divider()
        Button("Home") { model.home() }.keyboardShortcut("1", modifiers: [.command])
          .disabled(!model.canControl)
        Button("App Switcher") { model.appSwitcher() }.keyboardShortcut("2", modifiers: [.command])
          .disabled(!model.canControl)
        Button("Spotlight") { model.spotlight() }.keyboardShortcut("3", modifiers: [.command])
          .disabled(!model.canControl)
        Button("Control Center") { model.controlCenter() }.keyboardShortcut(
          "4", modifiers: [.command]
        ).disabled(!model.canControl)
        Button("Release All Inputs") { model.releaseInputs() }.keyboardShortcut(
          .escape, modifiers: [.command]
        ).disabled(!model.active)
        Button("Fit Window to iPhone") { model.fitWindow() }.keyboardShortcut("0").disabled(
          !model.hasPicture)
        Button("Rotate Right") { model.rotate() }
          .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!model.canControl)
        Button("Rotate Left") { model.rotate(clockwise: false) }
          .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(!model.canControl)
        Divider()
        Button("Reconnect Now") { model.reconnectNow() }.keyboardShortcut(
          "r", modifiers: [.command, .shift]
        ).disabled(!model.canReconnect)
        Button("Refresh Devices") { model.refresh() }.keyboardShortcut("r").disabled(model.active)
        Button("Disconnect") { model.disconnect() }.keyboardShortcut(
          "d", modifiers: [.command, .shift]
        ).disabled(!model.active)
        Divider()
        Button("Connection Diagnostics…") { model.showingDiagnostics = true }
      }
      CommandMenu("Automation") {
        Toggle("Enable Agent Access", isOn: Binding(
          get: { model.automationEnabled }, set: { model.setAutomationEnabled($0) }))
        Text(model.automationStatus)
        Menu("Port") {
          Toggle("Automatic", isOn: Binding(
            get: { model.automationPort == AutomationPort.automatic },
            set: { if $0 { model.setAutomationPort(AutomationPort.automatic) } }))
          Toggle("\(AutomationPort.preset)", isOn: Binding(
            get: { model.automationPort == AutomationPort.preset },
            set: { if $0 { model.setAutomationPort(AutomationPort.preset) } }))
          Toggle(customPortTitle, isOn: Binding(
            get: { ![AutomationPort.automatic, AutomationPort.preset].contains(model.automationPort) },
            set: { _ in model.chooseCustomAutomationPort() }))
        }
        Button("Stop Agent Action") { model.stopAgentAction() }
          .disabled(!model.automationBusy)
      }
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: MirrorModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    model.setAutomationEnabled(false)
    DispatchQueue.main.async {
      model.recording.stop {
        guard model.session != nil else {
          model.disconnect()
          sender.reply(toApplicationShouldTerminate: true)
          return
        }
        model.onSessionClosed = { sender.reply(toApplicationShouldTerminate: true) }
        model.disconnect()
      }
    }
    return .terminateLater
  }
}

struct MirrorWindow: View {
  @AppStorage("alwaysOnTop") private var alwaysOnTop = false
  @AppStorage("showDeviceBezel") private var showDeviceBezel = true
  @ObservedObject var model: MirrorModel
  @ObservedObject var recorder: RecordingController
  var body: some View {
    VStack(spacing: TitleBarMetrics.gap) {
      MirrorTitleBar(model: model, recorder: recorder)
        .padding([.horizontal, .top], TitleBarMetrics.margin)
      ZStack {
        PhoneFrame(screenSize: model.screenSize, showBezel: showDeviceBezel) { radius, inset in
          ZStack {
            if model.session != nil {
              MirrorSurface(model: model, cornerRadius: radius, bezelInset: inset)
                .id(model.sessionID).opacity(model.hasPicture ? 1 : 0)
            }
            if !model.hasPicture { connectionView }
          }
        }
        if let notice = model.screenshotNotice {
          VStack {
            Text(notice).font(.callout).padding(10)
              .background(.regularMaterial, in: Capsule()).padding(.top, 12)
            Spacer()
          }.allowsHitTesting(false)
        }
      }
    }
    // The bar replaces the titlebar, so it takes the titlebar's place at the very top.
    .ignoresSafeArea(.container, edges: .top)
    .background(MirrorWindowLevel(alwaysOnTop: alwaysOnTop).allowsHitTesting(false))
    .background(MirrorWindowChrome().allowsHitTesting(false))
    .navigationTitle(model.selected?.name ?? "iPhoneMirror")
    .alert(
      "Could not capture screenshot",
      isPresented: Binding(
        get: { model.screenshotError != nil },
        set: { if !$0 { model.screenshotError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { model.screenshotError = nil }
    } message: {
      Text(model.screenshotError ?? "")
    }
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
    .sheet(isPresented: $model.showingDiagnostics) { ConnectionDiagnosticsView(model: model) }
    .alert(
      "iPhone rotation",
      isPresented: Binding(
        get: { model.rotationNotice != nil },
        set: { if !$0 { model.rotationNotice = nil } }
      )
    ) {
      Button("OK", role: .cancel) { model.rotationNotice = nil }
    } message: {
      Text(model.rotationNotice ?? "")
    }
  }
  private var connectionView: some View {
    VStack(spacing: 0) {
      Spacer()
      Image(
        systemName: model.error == nil
          ? "iphone.gen3.radiowaves.left.and.right" : "cable.connector.slash"
      )
      .font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.secondary).padding(
        .bottom, 24)
      Text(model.connectionTitle)
        .font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
        .multilineTextAlignment(.center).foregroundStyle(.primary)
      Text(
        model.error
          ?? (model.active
            ? model.status : "Connect by USB, unlock your iPhone,\nand keep it within reach.")
      )
      .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      .lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 13).padding(
        .horizontal, 30)
      if model.active || model.discovering {
        ProgressView().controlSize(.small).padding(.top, 26)
        if model.lifecycle.desiredDevice != nil {
          Button("Reconnect now") { model.reconnectNow() }
            .buttonStyle(.borderedProminent).disabled(!model.canReconnect).padding(.top, 18)
          Button("Stop reconnecting") { model.disconnect() }
            .buttonStyle(.bordered).padding(.top, 18)
        }
      } else {
        if model.devices.count > 1 {
          Picker("iPhone", selection: $model.selection) {
            ForEach(model.devices) { device in Text(device.name).tag(device.id) }
          }.labelsHidden().frame(maxWidth: 230).padding(.top, 24)
        }
        Button(model.devices.isEmpty ? "Find iPhone" : "Mirror iPhone") {
          if model.devices.isEmpty { model.refresh() } else { model.connect() }
        }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 24)
      }
      Spacer()
      Button("Connection diagnostics…") { model.showingDiagnostics = true }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.bottom, 14)
      VStack(spacing: 5) {
        Text("USB FIRST · PERSONAL PREVIEW").font(
          .system(size: 9, weight: .semibold, design: .monospaced)
        ).tracking(1.5)
        Text("Requires Developer Mode and a device prepared in Xcode.").font(.system(size: 10))
      }.foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.bottom, 24)
        .padding(.horizontal, 20)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      // Shown on the phone's dark screen, whatever the Mac's appearance.
      .background(Color.black).environment(\.colorScheme, .dark)
  }
}

/// Simulator-style floating title bar: traffic lights (placed by MirrorWindowChrome), the
/// iPhone's name and status, and the most used hardware actions. Everything else lives in
/// the menu bar.
struct MirrorTitleBar: View {
  @ObservedObject var model: MirrorModel
  @ObservedObject var recorder: RecordingController
  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(model.selected?.name ?? "iPhoneMirror")
          .font(.system(size: 13, weight: .semibold))
        if let subtitle {
          Text(subtitle.text).font(.system(size: 11)).foregroundStyle(subtitle.style)
            .monospacedDigit()
        }
      }
      .lineLimit(1)
      .padding(.leading, TitleBarMetrics.trafficLightsWidth)
      Spacer(minLength: 0)
      HStack(spacing: 2) {
        Button {
          model.home()
        } label: {
          Image(systemName: "house")
        }.help("Home ⌘1").accessibilityLabel("Home").disabled(!model.canControl)
        Button {
          model.appSwitcher()
        } label: {
          Image(systemName: "square.on.square")
        }.help("App Switcher ⌘2").accessibilityLabel("App Switcher").disabled(!model.canControl)
        Button {
          model.saveScreenshot()
        } label: {
          Image(systemName: "camera")
        }.help("Save screenshot ⌘S · Copy screenshot ⇧⌘C").accessibilityLabel("Save screenshot")
          .disabled(!model.canCaptureScreenshot)
      }
      .buttonStyle(TitleBarButtonStyle())
      .padding(3)
      .background(Capsule().fill(Color.primary.opacity(0.06)))
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, minHeight: TitleBarMetrics.height, maxHeight: TitleBarMetrics.height)
    .contentShape(Rectangle())
    .gesture(WindowDragGesture())
    .allowsWindowActivationEvents(true)
    .glassEffect(.regular, in: .rect(cornerRadius: 17))
    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
  }
  private var subtitle: (text: String, style: Color)? {
    if recorder.recording {
      return (
        String(format: "Recording %d:%02d", recorder.elapsed / 60, recorder.elapsed % 60), .red
      )
    }
    if model.automationEnabled {
      return (
        model.automationBusy ? "Agent controlling iPhone" : "Agent access enabled", .accentColor
      )
    }
    return model.selected.map { ("iOS \($0.version)", .secondary) }
  }
}

private struct TitleBarButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(isEnabled ? .primary : .tertiary)
      .frame(width: 32, height: 28)
      .background(
        Capsule().fill(
          Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.08 : 0))
      )
      .contentShape(Capsule())
      .onHover { hovering = $0 }
  }
}
