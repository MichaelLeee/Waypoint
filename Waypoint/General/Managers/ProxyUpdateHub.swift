//
//  ProxyUpdateHub.swift
//  Waypoint
//

import Cocoa

/// Typed in-process event flow for proxy data changes, replacing the
/// stringly-typed `.proxyUpdate` / `.speedTestFinishForProxy` notifications.
///
/// All producers and consumers live on the main actor (menu rendering does),
/// so events may carry the `WaypointProxy` model directly. Subscribers
/// receive only events whose name matches the name they subscribed with.
@MainActor
final class ProxyUpdateHub {
    static let shared = ProxyUpdateHub()

    enum Event {
        /// A full model refresh for a proxy or group.
        case snapshot(WaypointProxy)
        /// A speed-test result: name, display string ("42 ms"/"fail"), raw value.
        case delay(name: String, display: String, value: Int?)
    }

    private struct Subscription {
        let name: String
        let continuation: AsyncStream<Event>.Continuation
    }

    private var subscriptions: [UUID: Subscription] = [:]

    func proxyEvents(for name: String) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            subscriptions[id] = Subscription(name: name, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscriptions[id] = nil
                }
            }
        }
    }

    func proxyDidUpdate(_ proxy: WaypointProxy) {
        deliver(.snapshot(proxy), name: proxy.name)
    }

    func delayDidUpdate(name: String, display: String, value: Int?) {
        deliver(.delay(name: name, display: display, value: value), name: name)
    }

    private func deliver(_ event: Event, name: String) {
        for subscription in subscriptions.values where subscription.name == name {
            subscription.continuation.yield(event)
        }
    }
}

// Safe: every producer and consumer runs on the main actor, so the payload
// (a non-Sendable WaypointProxy) never actually crosses isolation — the
// conformance exists only to satisfy the check on the nonisolated
// continuation.yield call.
extension ProxyUpdateHub.Event: @unchecked Sendable {}
