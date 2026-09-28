import AppKit
import MirrorCore
import SwiftUI

extension MirrorModel {
  func checkSetup() {
    guard !setupBusy else { return }
    // Mirroring proves every step, and the check would open a second tunnel beside it.
    if canControl {
      setupStatus = SetupStatus(
        ddiOnMac: true, connected: true, trusted: true, developerMode: true, ddiMounted: true,
        developerServices: true)
      return
    }
    setupBusy = true
    NativeSession.setupStatus(device: selection) { [weak self] status in
      Task { @MainActor in
        self?.setupStatus = status
        self?.setupBusy = false
      }
    }
  }

  func prepareIPhone(_ action: PrepareAction) {
    guard !setupBusy else { return }
    setupBusy = true
    setupMessage =
      action == .mountDeveloperImage ? "Preparing the iPhone…" : "Showing the setting…"
    NativeSession.prepare(device: selection, action) { [weak self] failure in
      Task { @MainActor in
        guard let self else { return }
        self.setupBusy = false
        self.setupMessage =
          failure
          ?? (action == .revealDeveloperMode
            ? "On the iPhone, open Settings › Privacy & Security › Developer Mode."
            : nil)
        self.checkSetup()
      }
    }
  }
}

/// Each prerequisite with its state and, when missing, how to fix it. Opens by itself when
/// a connection fails for lack of developer services.
struct SetupCheckView: View {
  @ObservedObject var model: MirrorModel
  @Environment(\.dismiss) private var dismiss
  private static let xcode = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Setup Check").font(.title2.weight(.semibold))
      Text("iPhoneMirror needs everything below. It prepares what it can by itself.")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 14) {
        row(
          .components, "Apple developer components",
          done: "Installed on this Mac.",
          needed:
            "Install Xcode from the App Store and open it once to install Apple’s developer components. You don’t need to use Xcode afterwards."
        ) {
          Button("Open App Store") { NSWorkspace.shared.open(Self.xcode) }
        }
        row(
          .trust, "iPhone trusts this Mac",
          done: "Paired.",
          needed: "Unlock the iPhone and tap Trust when it asks about this Mac.",
          unknown: "Connect the iPhone by USB and unlock it.")
        row(
          .developerMode, "Developer Mode",
          done: "On.",
          needed:
            "On the iPhone, open Settings › Privacy & Security › Developer Mode, turn it on, restart, then confirm. If the setting is missing, show it first."
        ) {
          Button("Show Developer Mode Setting") { model.prepareIPhone(.revealDeveloperMode) }
        }
        row(
          .services, "Developer services",
          done: model.setupStatus?.ddiVersion.map { "Ready (\($0))." } ?? "Ready.",
          needed:
            "iPhoneMirror prepares these when you connect, including after the iPhone restarts. It needs internet access: Apple signs them for your iPhone."
        ) {
          Button("Prepare iPhone") { model.prepareIPhone(.mountDeveloperImage) }
        }
      }
      if let message = model.setupMessage ?? model.setupStatus?.detail {
        Text(message).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if model.setupBusy { ProgressView().controlSize(.small) }
        Spacer()
        Button("Check Again") {
          model.setupMessage = nil
          model.checkSetup()
        }.disabled(model.setupBusy)
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 540)
    .onAppear {
      model.setupMessage = nil
      model.checkSetup()
    }
  }

  private func row(
    _ step: SetupStatus.Step, _ title: String, done: String, needed: String,
    unknown: String = "Waiting for the steps above.",
    @ViewBuilder fix: () -> some View = { EmptyView() }
  ) -> some View {
    let state = model.setupStatus?.state(of: step) ?? .unknown
    return HStack(alignment: .top, spacing: 12) {
      Image(
        systemName: state == .done
          ? "checkmark.circle.fill"
          : state == .needed ? "exclamationmark.circle.fill" : "circle.dashed"
      )
      .font(.title3)
      .foregroundStyle(state == .done ? .green : state == .needed ? .orange : .secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(state == .done ? done : state == .needed ? needed : unknown)
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if state == .needed { fix().disabled(model.setupBusy).padding(.top, 2) }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
