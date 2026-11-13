import Foundation

/// Two-slot replacement. The caller serializes all operations for a logical item.
/// `add` must insert only (never upsert), and `remove` must accept a missing slot.
/// A pending value is always newer than, or identical to, the primary value.
struct RecoverableSecretReplacement {
  enum Slot: Hashable { case primary, pending }

  let add: (Slot, Data) throws -> Void
  let read: (Slot) throws -> Data?
  let remove: (Slot) throws -> Void

  func save(_ data: Data) throws {
    // This is the commit point. A leftover pending item makes add fail without changing it.
    // Never delete a pending value to make room: it may be the only copy of issued codes.
    try add(.pending, data)
    // Once committed, report success so callers retain metadata for this new value.
    // A later load repairs promotion; pending remains authoritative in the meantime.
    try? promote(data)
  }

  func load() throws -> Data? {
    // Authentication/read errors must propagate; falling back could resurrect issued codes.
    if let data = try read(.pending) {
      // A repair failure leaves pending authoritative. Return the authenticated latest value;
      // a later save still cannot overwrite it until repair succeeds.
      try? promote(data)
      return data
    }
    return try read(.primary)
  }

  private func promote(_ data: Data) throws {
    try remove(.primary)
    try add(.primary, data)
    // Only discard pending once an identical primary is durably present.
    try remove(.pending)
  }

  func delete() throws {
    // Remove the older copy first. Failure must not expose it as a fallback.
    try remove(.primary)
    try remove(.pending)
  }
}
