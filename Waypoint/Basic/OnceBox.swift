//
//  OnceBox.swift
//  Waypoint
//  Runs a body at most once, so a reply that arrives twice is harmless.
//

import Foundation

/// Runs `body` for the first caller only; later calls are ignored. Safe to call
/// from any thread.
///
/// Every caller races an XPC reply against a connection error handler or a
/// timeout, and those arrive on different queues. Resuming a
/// `CheckedContinuation` twice traps the process, so the first caller decides
/// the outcome and the rest drop out. The body runs after the lock is released,
/// so it never holds the lock across an awaiting task waking up.
final class OnceBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let body: (Value) -> Void

    init(_ body: @escaping (Value) -> Void) {
        self.body = body
    }

    func resume(_ value: Value) {
        lock.lock()
        let shouldRun = !done
        done = true
        lock.unlock()
        if shouldRun {
            body(value)
        }
    }
}
