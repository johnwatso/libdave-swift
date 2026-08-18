import Foundation
import CDave

/// Keeps C callback contexts alive after their Swift owners have gone away.
///
/// The native C API stores `void *` callback contexts but does not provide an
/// unregister-and-drain operation, nor does it document that destruction
/// waits for callbacks already queued on another thread. Releasing a Swift
/// object immediately after destroying its native owner would therefore leave
/// a possible use-after-free in the C-to-Swift callback trampoline.
///
/// Contexts are registered while their owner is live and *retired* when the
/// owner tears down. A retired context stays allocated for
/// ``retirementGrace`` so that a callback already in flight lands on a valid
/// (deactivated, inert) object, and is then reclaimed. Native destruction is
/// synchronous in the bundled implementation, so a callback arriving after
/// the grace window would mean the C library invoked a context for an object
/// it destroyed tens of seconds earlier — far outside anything it does today.
///
/// Reclaiming matters because registrations are not rare: one per session,
/// one per rebuilt encryptor, and one per pairwise-fingerprint request. A
/// long-running voice client that reconnects and verifies identities would
/// otherwise grow this table for the lifetime of the process.
internal final class DaveNativeCallbackContextRetainer: @unchecked Sendable {
    static let shared = DaveNativeCallbackContextRetainer()

    /// How long a retired context remains allocated before it is reclaimed.
    private static let retirementGrace: Duration = .seconds(30)
    /// Hard ceiling on retained contexts. Reached only if a host registers
    /// contexts far faster than the grace window reclaims them; the oldest
    /// retired entries are dropped first, and live entries are never dropped.
    private static let maximumRetainedContexts = 512

    private struct Entry {
        let id: ObjectIdentifier
        let context: AnyObject
        var retiredAt: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    /// Insertion-ordered, so eviction can prefer the longest-retired entries.
    private var entries: [Entry] = []

    private init() {}

    func retainForNativeLifetime(_ context: AnyObject) {
        lock.lock()
        entries.append(Entry(id: ObjectIdentifier(context), context: context, retiredAt: nil))
        reclaimLocked()
        lock.unlock()
    }

    /// Marks a context as belonging to a torn-down owner. It is reclaimed once
    /// the grace window has elapsed.
    func retireAfterNativeLifetime(_ context: AnyObject) {
        let id = ObjectIdentifier(context)
        lock.lock()
        if let index = entries.lastIndex(where: { $0.id == id }), entries[index].retiredAt == nil {
            entries[index].retiredAt = ContinuousClock.now
        }
        reclaimLocked()
        lock.unlock()
    }

    /// Number of contexts currently held. Exposed for tests asserting that the
    /// table does not grow without bound.
    var retainedContextCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Drops retired contexts whose grace window has elapsed, then enforces the
    /// hard ceiling by dropping the longest-retired entries first. A
    /// monotonic clock is used so a wall-clock adjustment cannot reclaim a
    /// context early.
    private func reclaimLocked() {
        let now = ContinuousClock.now
        entries.removeAll { entry in
            guard let retiredAt = entry.retiredAt else { return false }
            return now - retiredAt >= Self.retirementGrace
        }

        guard entries.count > Self.maximumRetainedContexts else { return }
        var overflow = entries.count - Self.maximumRetainedContexts
        var survivors: [Entry] = []
        survivors.reserveCapacity(entries.count)
        for entry in entries {
            if overflow > 0, entry.retiredAt != nil {
                overflow -= 1
                continue
            }
            survivors.append(entry)
        }
        entries = survivors
    }
}

/// Resumes exactly one awaiting caller, whichever of several possible
/// deliveries arrives first, and tolerates a delivery that happens before the
/// continuation is attached.
///
/// This is what lets an `async` wrapper around a C callback impose a timeout:
/// the native callback and the timeout both call ``deliver(_:)``, and only the
/// first one resumes the continuation.
internal final class DaveSingleShotResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var bufferedValue: Value?
    private var hasDelivered = false
    private var hasResumed = false

    init() {}

    /// Attaches the awaiting continuation. If a value was already delivered,
    /// the continuation resumes immediately.
    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if hasDelivered, !hasResumed, let value = bufferedValue {
            hasResumed = true
            bufferedValue = nil
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Delivers a result. Only the first call has any effect, so a late native
    /// callback can never resume a continuation twice.
    func deliver(_ value: Value) {
        lock.lock()
        guard !hasDelivered else {
            lock.unlock()
            return
        }
        hasDelivered = true
        if let continuation, !hasResumed {
            hasResumed = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        bufferedValue = value
        lock.unlock()
    }
}

/// Internal class to route C-style callbacks to Swift closures in a thread-safe manner.
internal final class DaveSessionCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var _onMLSFailure: (@Sendable (String, String) -> Void)?
    private var _lastFailure: (source: String, reason: String)?

    var onMLSFailure: (@Sendable (String, String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onMLSFailure
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return }
            _onMLSFailure = newValue
        }
    }

    /// Records a native MLS failure synchronously (so callers can read the
    /// reason immediately after a native call returns) and forwards it to the
    /// registered closure. The native side may invoke the failure callback
    /// inline during `processCommit`/`processWelcome`/`processProposals`; the
    /// closure path hops to the actor asynchronously, so the synchronous
    /// `_lastFailure` slot is what lets us attach the real reason to a throw.
    func recordFailure(source: String, reason: String) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        _lastFailure = (source, reason)
        let closure = _onMLSFailure
        lock.unlock()
        closure?(source, reason)
    }

    /// Returns and clears the most recently recorded native failure, if any.
    func takeLastFailure() -> (source: String, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        let failure = _lastFailure
        _lastFailure = nil
        return failure
    }

    /// Stops routing callbacks and drops application-owned state. The bridge
    /// itself remains retained by ``DaveNativeCallbackContextRetainer`` so a
    /// late native invocation can safely return without touching a released
    /// Swift object.
    func deactivate() {
        lock.lock()
        isActive = false
        _onMLSFailure = nil
        _lastFailure = nil
        lock.unlock()
    }

    init() {}
}

/// Global MLS Failure callback router.
internal func daveMLSFailureCallbackBridge(
    source: UnsafePointer<CChar>?,
    reason: UnsafePointer<CChar>?,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveSessionCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    let sourceStr = source.flatMap { String(cString: $0) } ?? "Unknown"
    let reasonStr = reason.flatMap { String(cString: $0) } ?? "Unknown"
    bridge.recordFailure(source: sourceStr, reason: reasonStr)
}

/// Single-shot bridge for one pairwise-fingerprint request.
///
/// Each `getPairwiseFingerprint` call gets its own bridge so concurrent
/// requests cannot clobber each other's closure (the previous shared-bridge
/// design could drop a callback, leaving an awaiting caller wedged forever).
internal final class DaveFingerprintCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data?) -> Void)?

    init(callback: @escaping @Sendable (Data?) -> Void) {
        self.callback = callback
    }

    /// Delivers at most once. A malformed or late native callback cannot
    /// resume a Swift continuation twice.
    func deliver(_ fingerprint: Data?) {
        lock.lock()
        let callback = self.callback
        let wasPending = callback != nil
        self.callback = nil
        lock.unlock()
        callback?(fingerprint)
        if wasPending {
            // This bridge is single-shot: once the one expected callback has
            // been consumed, its tombstone can start aging out instead of
            // being retained for the lifetime of the process.
            DaveNativeCallbackContextRetainer.shared.retireAfterNativeLifetime(self)
        }
    }
}

/// Global Pairwise Fingerprint callback router.
///
/// The bridge is retained for native lifetime because the C API does not
/// document callback timing or a drain operation. `deliver` itself is
/// single-shot, so duplicate callbacks are harmless.
internal func davePairwiseFingerprintCallbackBridge(
    fingerprint: UnsafePointer<UInt8>?,
    length: Int,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveFingerprintCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    let data = fingerprint.flatMap { length > 0 ? Data(bytes: $0, count: length) : nil }
    bridge.deliver(data)
}

/// Internal class to route encryptor callbacks in a thread-safe manner.
internal final class DaveEncryptorCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var _onProtocolVersionChanged: (@Sendable () -> Void)?

    var onProtocolVersionChanged: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onProtocolVersionChanged
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return }
            _onProtocolVersionChanged = newValue
        }
    }

    /// Invokes the current callback, if this bridge still belongs to a live
    /// encryptor. Copying the closure under the lock keeps callback replacement
    /// and native delivery race-free.
    func notifyProtocolVersionChanged() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        let closure = _onProtocolVersionChanged
        lock.unlock()
        closure?()
    }

    /// Makes all future native deliveries no-ops and releases the callback
    /// closure. See ``DaveNativeCallbackContextRetainer`` for why the bridge
    /// object itself cannot be reclaimed deterministically yet.
    func deactivate() {
        lock.lock()
        isActive = false
        _onProtocolVersionChanged = nil
        lock.unlock()
    }

    init() {}
}

/// Global Encryptor Protocol Version Changed callback router.
internal func daveEncryptorProtocolVersionChangedCallbackBridge(userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveEncryptorCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.notifyProtocolVersionChanged()
}
