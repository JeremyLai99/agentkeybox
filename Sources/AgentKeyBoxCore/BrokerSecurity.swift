import Foundation

public actor BrokerReplayGuard {
  private var seen: [UUID: Date] = [:]
  private let freshnessWindow: TimeInterval

  public init(freshnessWindow: TimeInterval = 300) {
    self.freshnessWindow = freshnessWindow
  }

  public func accept(_ request: BrokerRequest, now: Date = Date()) -> Bool {
    let delta = abs(now.timeIntervalSince(request.issuedAt))
    guard delta <= freshnessWindow else { return false }
    guard seen[request.requestID] == nil else { return false }

    seen[request.requestID] = now
    let cutoff = now.addingTimeInterval(-freshnessWindow * 2)
    seen = seen.filter { $0.value >= cutoff }
    return true
  }
}
