import Combine
import Sparkle

@MainActor final class Updater: ObservableObject {
  private let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  @Published private(set) var canCheckForUpdates = false
  private var subscription: AnyCancellable?

  init() {
    subscription = controller.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .assign(to: \.canCheckForUpdates, on: self)
  }

  func checkForUpdates() { controller.updater.checkForUpdates() }
}
