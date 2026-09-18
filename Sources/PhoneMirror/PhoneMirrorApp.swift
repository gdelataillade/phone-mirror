import AppKit
import SwiftUI

@main struct PhoneMirrorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = MirrorModel()
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
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .pasteboard) {
        Button("Paste Text to iPhone") { model.pasteText() }.keyboardShortcut("v").disabled(
          !model.canControl)
      }
      CommandMenu("iPhone") {
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
      }
    }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: MirrorModel?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    guard model.session != nil else {
      model.disconnect()
      return .terminateNow
    }
    model.onSessionClosed = { sender.reply(toApplicationShouldTerminate: true) }
    model.disconnect()
    return .terminateLater
  }
}

struct MirrorWindow: View {
  @ObservedObject var model: MirrorModel
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "iphone.gen3").font(.system(size: 18)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.selected?.name ?? "PhoneMirror").font(.system(size: 13, weight: .semibold))
          Text(
            model.selected.map { "iOS \($0.version) · USB" } ?? "A direct connection to your iPhone"
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        if model.active {
          Button {
            model.reconnectNow()
          } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 16))
          }
          .buttonStyle(.plain).help("Reconnect now ⇧⌘R").disabled(!model.canReconnect)
          .accessibilityLabel("Reconnect now")
          Button {
            model.disconnect()
          } label: {
            Image(systemName: "xmark.circle").font(.system(size: 18))
          }
          .buttonStyle(.plain).help("Disconnect and stop automatic reconnection")
          .accessibilityLabel(
            "Disconnect")
        } else {
          Button {
            model.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain).help("Refresh devices").disabled(model.discovering)
          .accessibilityLabel("Refresh devices")
        }
      }.padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 16)
      Divider()
      ZStack {
        Color(red: 0.035, green: 0.04, blue: 0.045)
        if model.session != nil {
          MirrorSurface(model: model).id(model.sessionID).opacity(model.hasPicture ? 1 : 0)
        }
        if !model.hasPicture { connectionView }
      }
      Divider()
      HStack(spacing: 7) {
        Circle().fill(model.hasPicture ? Color.green : Color.secondary.opacity(0.5)).frame(
          width: 6, height: 6)
        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 4)
        if model.hasPicture {
          Text("\(model.fps) fps").font(.system(size: 10, design: .monospaced)).foregroundStyle(
            .tertiary)
          Button {
            model.rotate()
          } label: {
            Image(systemName: "rotate.right")
          }.buttonStyle(.borderless).help("Rotate iPhone right ⌥⌘→")
            .accessibilityLabel("Rotate iPhone right").disabled(!model.canControl)
          Button {
            model.home()
          } label: {
            Image(systemName: "house")
          }.buttonStyle(.borderless).help("Home ⇧⌘H").accessibilityLabel("Home")
          Button {
            model.appSwitcher()
          } label: {
            Image(systemName: "square.on.square")
          }.buttonStyle(.borderless).help("App Switcher ⇧⌘A").accessibilityLabel("App Switcher")
        }
      }.padding(.horizontal, 16).frame(height: 40)
    }.background(.regularMaterial)
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
      .font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.white.opacity(0.8)).padding(
        .bottom, 24)
      Text(model.connectionTitle)
        .font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
        .multilineTextAlignment(.center).foregroundStyle(.white)
      Text(
        model.error
          ?? (model.active
            ? model.status : "Connect by USB, unlock your iPhone,\nand keep it within reach.")
      )
      .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
      .lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 13).padding(
        .horizontal, 30)
      if model.active || model.discovering {
        ProgressView().controlSize(.small).tint(.white).padding(.top, 26)
        if model.lifecycle.desiredDevice != nil {
          Button("Reconnect now") { model.reconnectNow() }
            .buttonStyle(.borderedProminent).disabled(!model.canReconnect).padding(.top, 18)
          Button("Stop reconnecting") { model.disconnect() }
            .buttonStyle(.bordered).tint(.white).padding(.top, 18)
        }
      } else {
        if model.devices.count > 1 {
          Picker("iPhone", selection: $model.selection) {
            ForEach(model.devices) { device in Text(device.name).tag(device.id) }
          }.labelsHidden().frame(maxWidth: 230).padding(.top, 24)
        }
        Button(model.devices.isEmpty ? "Find iPhone" : "Mirror iPhone") {
          if model.devices.isEmpty { model.refresh() } else { model.connect() }
        }.buttonStyle(.borderedProminent).controlSize(.large).tint(
          Color(red: 0.30, green: 0.56, blue: 0.95)
        ).padding(.top, 24)
      }
      Spacer()
      VStack(spacing: 5) {
        Text("USB FIRST · PERSONAL PREVIEW").font(
          .system(size: 9, weight: .semibold, design: .monospaced)
        ).tracking(1.5)
        Text("Requires Developer Mode and a device prepared in Xcode.").font(.system(size: 10))
      }.foregroundStyle(.white.opacity(0.3)).multilineTextAlignment(.center).padding(.bottom, 24)
        .padding(.horizontal, 20)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
