//
//  OnceBoxTests.swift
//  WaypointTests
//

import Foundation
import Testing
@testable import Waypoint

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("OnceBox")
struct OnceBoxTests {

    private enum SampleError: Error, Equatable {
        case late
    }

    @Test("A single resume delivers its result to the awaiting task")
    func singleResumeDeliversResult() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox<Result<Void, Error>> { continuation.resume(with: $0) }
            once.resume(.success(()))
        }
    }

    @Test("A failure result propagates instead of being swallowed")
    func failurePropagates() async {
        await #expect(throws: SampleError.late) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceBox<Result<Void, Error>> { continuation.resume(with: $0) }
                once.resume(.failure(SampleError.late))
            }
        }
    }

    // Resuming a CheckedContinuation twice traps the process, so this test
    // fails by crashing if the done-flag guard is ever dropped. That is the
    // intended signal: the guard's whole job is preventing that trap.
    @Test("Resuming a second time is ignored rather than trapping")
    func secondResumeIsIgnored() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceBox<Result<Void, Error>> { continuation.resume(with: $0) }
            once.resume(.success(()))
            once.resume(.failure(SampleError.late))
        }
    }

    // The race the primitive exists for: an XPC reply block and a connection
    // error handler landing on different queues at the same moment. Without
    // the lock this traps within a few rounds.
    @Test("Concurrent resumes from many threads deliver exactly one result")
    func concurrentResumesDeliverExactlyOne() async throws {
        for _ in 0 ..< 100 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceBox<Result<Void, Error>> { continuation.resume(with: $0) }
                for _ in 0 ..< 8 {
                    DispatchQueue.global().async { once.resume(.success(())) }
                }
            }
        }
    }

    // The continuation-less flavor: a plain callback, where a second run would
    // double-report rather than trap. The body must still run exactly once.
    @Test("The callback body runs exactly once under concurrent resumes")
    func callbackBodyRunsExactlyOnce() async {
        for _ in 0 ..< 20 {
            let counter = CallbackCounter()
            let once = OnceBox<Int> { _ in counter.increment() }
            await withTaskGroup(of: Void.self) { group in
                for index in 0 ..< 64 {
                    group.addTask { once.resume(index) }
                }
            }
            #expect(counter.value == 1)
        }
    }
}
