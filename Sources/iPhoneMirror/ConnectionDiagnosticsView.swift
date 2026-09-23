import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionDiagnosticsView: View {
  @ObservedObject var model: MirrorModel
  @Environment(\.dismiss) private var dismiss
  @State private var exportError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connection diagnostics").font(.title2.weight(.semibold))
      Text(model.diagnosticHealth.guidance).foregroundStyle(.secondary)
      Text(
        "This report contains connection counters and recent events. It excludes your screen, typed text, clipboard, device name and identifiers."
      )
      .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        Text(model.diagnosticReport).font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Button("Copy Report") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
        }
        Button("Save Report…") { save() }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 580, height: 510)
      .alert(
        "Could not save report",
        isPresented: Binding(
          get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(exportError ?? "")
      }
  }
  private func save() {
    let report = model.diagnosticReport
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "iPhoneMirror-diagnostics.txt"
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      do { try report.write(to: url, atomically: true, encoding: .utf8) } catch {
        exportError = error.localizedDescription
      }
    }
  }
}
