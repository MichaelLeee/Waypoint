//
//  ProxyUpdateHubTests.swift
//  WaypointNetworkingTests
//

import Testing
@testable import WaypointNetworking

@MainActor
struct ProxyUpdateHubTests {
    private func firstEvent(
        of stream: AsyncStream<ProxyUpdateHub.Event>
    ) async -> ProxyUpdateHub.Event? {
        var result: ProxyUpdateHub.Event?
        for await event in stream {
            result = event
            break
        }
        return result
    }

    @Test func snapshotDeliveredOnlyToMatchingName() async {
        let hub = ProxyUpdateHub()
        let streamA = hub.proxyEvents(for: "A")
        let streamB = hub.proxyEvents(for: "B")
        hub.proxyDidUpdate(WaypointProxy(
            name: "A", type: .shadowsocks, all: nil, history: [], now: nil, alive: nil))

        guard case .snapshot(let proxy)? = await firstEvent(of: streamA) else {
            Issue.record("expected snapshot on A")
            return
        }
        #expect(proxy.name == "A")

        // B never receives an event; collect with a cancel to prove it stays empty.
        let counter = Task { @MainActor in
            var count = 0
            for await _ in streamB { count += 1 }
            return count
        }
        for _ in 0 ..< 10 { await Task.yield() }
        counter.cancel()
        #expect(await counter.value == 0)
    }

    @Test func delayEventCarriesDisplayAndValue() async {
        let hub = ProxyUpdateHub()
        let stream = hub.proxyEvents(for: "Proxy")
        hub.delayDidUpdate(name: "Proxy", display: "42 ms", value: 42)

        guard case .delay(let name, let display, let value)? = await firstEvent(of: stream) else {
            Issue.record("expected delay event")
            return
        }
        #expect(name == "Proxy")
        #expect(display == "42 ms")
        #expect(value == 42)
    }

    @Test func unsubscribesOnTermination() async {
        let hub = ProxyUpdateHub()
        let listener = Task { @MainActor in
            for await _ in hub.proxyEvents(for: "A") {}
        }
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(hub.subscriptionCount == 1)

        listener.cancel()
        // onTermination removes the subscription via a hop to the main actor.
        for _ in 0 ..< 50 where hub.subscriptionCount != 0 { await Task.yield() }
        #expect(hub.subscriptionCount == 0)
    }
}
