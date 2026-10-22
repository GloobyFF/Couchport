import Foundation
import os.lock

/// Lock-free atomic counter for high-frequency metrics (frame counting at 60fps).
/// Uses unfair lock for minimal contention - faster than NSLock but still safe.
final class AtomicCounter: @unchecked Sendable {
    private var storage: Int64 = 0
    private var lock = os_unfair_lock()

    func increment() {
        os_unfair_lock_lock(&lock)
        storage += 1
        os_unfair_lock_unlock(&lock)
    }

    func reset() -> Int64 {
        os_unfair_lock_lock(&lock)
        let current = storage
        storage = 0
        os_unfair_lock_unlock(&lock)
        return current
    }

    var value: Int64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storage
    }
}

/// Atomic storage for a single value, using unfair lock for minimal overhead.
/// Faster than NSLock for brief reads/writes (like size/generation counters).
final class AtomicValue<T>: @unchecked Sendable {
    private var storage: T
    private var lock = os_unfair_lock()

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return storage
        }
        set {
            os_unfair_lock_lock(&lock)
            storage = newValue
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Atomically updates the value and returns the old one.
    func swap(_ newValue: T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let old = storage
        storage = newValue
        return old
    }
}
