import Foundation

/// What `pm_prepare_status` reports. A prerequisite is nil when it could not be checked
/// because an earlier one failed (for example no USB iPhone, or it doesn't trust this Mac).
public struct SetupStatus: Decodable, Equatable {
  public enum Step: CaseIterable { case components, trust, developerMode, services }
  public enum State: Equatable { case done, needed, unknown }

  public let ddiOnMac: Bool
  public let connected: Bool
  public let trusted: Bool?
  public let developerMode: Bool?
  public let ddiMounted: Bool?
  public let ddiVersion: String?
  /// The first problem found, in words the user can act on.
  public let detail: String?

  public init(
    ddiOnMac: Bool, connected: Bool, trusted: Bool? = nil, developerMode: Bool? = nil,
    ddiMounted: Bool? = nil, ddiVersion: String? = nil, detail: String? = nil
  ) {
    self.ddiOnMac = ddiOnMac
    self.connected = connected
    self.trusted = trusted
    self.developerMode = developerMode
    self.ddiMounted = ddiMounted
    self.ddiVersion = ddiVersion
    self.detail = detail
  }

  public func state(of step: Step) -> State {
    switch step {
    // A phone Xcode already prepared keeps its developer image across restarts, so the
    // Mac's copy is only needed to prepare a phone that has none.
    case .components: return ddiOnMac || ddiMounted == true ? .done : .needed
    case .trust: return connected ? Self.state(trusted) : .unknown
    case .developerMode: return Self.state(developerMode)
    case .services: return Self.state(ddiMounted)
    }
  }

  public var isReady: Bool { Step.allCases.allSatisfy { state(of: $0) == .done } }

  private static func state(_ value: Bool?) -> State {
    value.map { $0 ? .done : .needed } ?? .unknown
  }
}

/// The backend starts a connection failure with this when the developer services are
/// missing and preparing them failed too; the app then opens Setup Check.
public let developerServicesUnavailablePrefix = "Developer services are unavailable."
