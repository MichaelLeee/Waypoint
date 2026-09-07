//
//  ProxyUpdateHub.swift
//  WaypointNetworking
//  Typed in-process event flow for proxy data changes, replacing the
//  stringly-typed `.proxyUpdate` / `.speedTestFinishForProxy` notifications.
//
//  All producers and consumers live on the main actor (menu rendering does),
//  so events may carry the `WaypointProxy` model directly. Subscribers
//  receive only events whose name matches the name they subscribed with.
//

import Foundation

@MainActor
public final class ProxyUpdateHub {
    public static let shared = ProxyUpdateHub()

    public enum Event: Sendable {
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

    public init() {}

    public func proxyEvents(for name: String) -> AsyncStream<Event> {
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

    public func proxyDidUpdate(_ proxy: WaypointProxy) {
        deliver(.snapshot(proxy), name: proxy.name)
    }

    public func delayDidUpdate(name: String, display: String, value: Int?) {
        deliver(.delay(name: name, display: display, value: value), name: name)
    }

    public var subscriptionCount: Int { subscriptions.count }

    private func deliver(_ event: Event, name: String) {
        for subscription in subscriptions.values where subscription.name == name {
            subscription.continuation.yield(event)
        }
    }
}
