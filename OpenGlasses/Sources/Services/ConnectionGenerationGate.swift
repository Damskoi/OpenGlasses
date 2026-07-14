import Foundation

/// Plan BR P3 — stale-callback guard for the realtime WebSocket lifecycles.
///
/// Both realtime services reuse one URLSession delegate whose closures are overwritten on
/// every `connect()`. A cancelled socket task's *late* terminal callback (didClose /
/// didCompleteWithError) therefore fires the NEW connection's closures — a spurious
/// failure/reconnect on top of a healthy socket. Plan BD's reconnect coalescing narrows
/// the window; this closes it: `connect()` advances the gate and captures its generation,
/// and every callback (open/close/error, connect-timeout, receive loop) no-ops unless its
/// generation is still current. `disconnect()` advances too, so post-teardown stragglers
/// are stale by construction.
struct ConnectionGenerationGate {
    private(set) var current: UInt64 = 0

    /// New connection attempt (or teardown) — everything captured before this is stale.
    mutating func advance() -> UInt64 {
        current += 1
        return current
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }
}
