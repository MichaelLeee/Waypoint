//
//  ResumeOnceTests.swift
//  WaypointTests
//

import Foundation
import Testing
@testable import Waypoint

@Suite("ResumeOnce")
struct ResumeOnceTests {

    private enum SampleError: Error, Equatable {
        case late
    }

    @Test("A single resume delivers its result to the awaiting task")
    func singleResumeDeliversResult() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ResumeOnce(continuation).resume(.success(()))
        }
    }

    @Test("A failure result propagates instead of being swallowed")
    func failurePropagates() async {
        await #expect(throws: SampleError.late) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ResumeOnce(continuation).resume(.failure(SampleError.late))
            }
        }
    }

    // Resuming a CheckedContinuation twice traps the process, so this test
    // fails by crashing if the done-flag guard is ever dropped. That is the
    // intended signal: the guard's whole job is preventing that trap.
    @Test("Resuming a second time is ignored rather than trapping")
    func secondResumeIsIgnored() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
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
                let once = ResumeOnce(continuation)
                for _ in 0 ..< 8 {
                    DispatchQueue.global().async { once.resume(.success(())) }
                }
            }
        }
    }
}
