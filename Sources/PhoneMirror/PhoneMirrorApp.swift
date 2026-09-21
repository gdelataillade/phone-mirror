import AppKit
import SwiftUI

@main struct PhoneMirrorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = MirrorModel()
  @AppStorage("alwaysOnTop") private var alwaysOnTop = false
  @AppStorage("showDeviceBezel") private var showDeviceBezel = true
  var body: some Scene {
    Window("PhoneMirror", id: "mirror") {
      MirrorWindow(model: model)
        .frame(minWidth: 360, minHeight: model.isLandscape ? 360 : 580)
        .onAppear {
          appDelegate.model = model
          model.refresh()
          NSApp.setActivationPolicy(.regular)
          NSApp.activate(ignoringOtherApps: true)
        }
    }
    .defaultSize(width: 440, height: 820)
    .windowToolbarStyle(.unified(showsTitle: true))
    .commands {
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
        Divider()
        Button("Home") { model.home() }.keyboardShortcut("h", modifiers: [.command, .shift])
          .disabled(!model.canControl)
        Button("App Switcher") { model.appSwitcher() }.keyboardShortcut(
          "a", modifiers: [.command, .shift]
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
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: MirrorModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
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
  var body: some View {
    ZStack {
      if model.session != nil {
        FramedMirror(model: model, showBezel: showDeviceBezel)
          .id(model.sessionID).opacity(model.hasPicture ? 1 : 0)
      }
      if !model.hasPicture { connectionView }
      if let notice = model.screenshotNotice {
        VStack {
          Text(notice).font(.callout).padding(10)
            .background(.regularMaterial, in: Capsule()).padding(.top, 12)
          Spacer()
        }.allowsHitTesting(false)
      }
    }
    .background(.regularMaterial)
    .background(MirrorWindowLevel(alwaysOnTop: alwaysOnTop).allowsHitTesting(false))
    .background(WindowGlassBackground().allowsHitTesting(false))
    .navigationTitle(model.selected?.name ?? "PhoneMirror")
    .navigationSubtitle(model.selected.map { "iOS \($0.version)" } ?? "")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Circle().fill(model.hasPicture ? Color.green : Color.secondary.opacity(0.5)).frame(
          width: 7, height: 7
        ).help(model.hasPicture ? "\(model.status) · \(model.fps) fps" : model.status)
        Button {
          alwaysOnTop.toggle()
        } label: {
          Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
        }
        .help(alwaysOnTop ? "Turn off Always on Top ⌥⌘T" : "Always on Top ⌥⌘T")
        .accessibilityLabel("Always on Top")
        .accessibilityValue(alwaysOnTop ? "On" : "Off")
        if model.hasPicture {
          RecordingButton(model: model, recorder: model.recording)
          Button {
            model.saveScreenshot()
          } label: {
            Image(systemName: "camera")
          }.help("Save screenshot ⌘S · Copy screenshot ⇧⌘C")
            .accessibilityLabel("Save screenshot").disabled(!model.canCaptureScreenshot)
          Button {
            model.rotate()
          } label: {
            Image(systemName: "rotate.right")
          }.help("Rotate iPhone right ⌥⌘→")
            .accessibilityLabel("Rotate iPhone right").disabled(!model.canControl)
          Button {
            model.home()
          } label: {
            Image(systemName: "house")
          }.help("Home ⇧⌘H").accessibilityLabel("Home").disabled(!model.canControl)
          Button {
            model.appSwitcher()
          } label: {
            Image(systemName: "square.on.square")
          }.help("App Switcher ⇧⌘A").accessibilityLabel("App Switcher").disabled(!model.canControl)
        }
        Menu {
          Toggle("Show iPhone Bezel", isOn: $showDeviceBezel)
          Divider()
          if model.active {
            Button("Reconnect Now") { model.reconnectNow() }.disabled(!model.canReconnect)
            Button("Disconnect") { model.disconnect() }
          } else {
            Button("Refresh Devices") { model.refresh() }.disabled(model.discovering)
          }
          Divider()
          Button("Connection Diagnostics…") { model.showingDiagnostics = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }.accessibilityLabel("More options")
      }
    }
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
  }
}
