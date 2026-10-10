import Testing
import WaypointNetworking
@testable import Waypoint

/// The menu is refreshed on a timer while it is open, so the change detection
/// decides whether a tick costs nothing or redraws rows. Real selection changes
/// (an auto-selecting group picking another node, a change made in the
/// dashboard or by another client) have to come through; an unchanged snapshot
/// has to stay silent.
@MainActor
struct ProxyRefreshTests {
    private func proxy(_ name: String,
                       type: WaypointProxyType = .select,
                       now: String? = nil,
                       alive: Bool? = true) -> WaypointProxy {
        WaypointProxy(name: name,
                      type: type,
                      all: ["a", "b"],
                      history: [],
                      now: now,
                      alive: alive)
    }

    @Test("An unchanged snapshot publishes nothing")
    func unchangedSnapshotPublishesNothing() {
        let proxies = [proxy("GLOBAL", now: "a"), proxy("a"), proxy("b")]
        let first = MenuItemFactory.changedProxies(proxies, since: [:])
        #expect(first.changed.count == 3)

        let second = MenuItemFactory.changedProxies(proxies, since: first.fingerprints)
        #expect(second.changed.isEmpty)
        #expect(second.fingerprints == first.fingerprints)
    }

    @Test("A group changing its selected node publishes that group")
    func selectionChangePublishesThatGroupOnly() {
        let before = [proxy("GLOBAL", now: "a"), proxy("a"), proxy("b")]
        let baseline = MenuItemFactory.changedProxies(before, since: [:]).fingerprints

        let after = [proxy("GLOBAL", now: "b"), proxy("a"), proxy("b")]
        let result = MenuItemFactory.changedProxies(after, since: baseline)

        #expect(result.changed.map(\.name) == ["GLOBAL"])
        #expect(result.changed.first?.now == "b")
    }

    @Test("A node going dead publishes that node")
    func aliveChangePublishesThatNode() {
        let before = [proxy("GLOBAL", now: "a"), proxy("a"), proxy("b")]
        let baseline = MenuItemFactory.changedProxies(before, since: [:]).fingerprints

        let after = [proxy("GLOBAL", now: "a"), proxy("a"), proxy("b", alive: false)]
        let result = MenuItemFactory.changedProxies(after, since: baseline)

        #expect(result.changed.map(\.name) == ["b"])
    }

    @Test("A group that has never been seen is published")
    func newProxyIsPublished() {
        let baseline = MenuItemFactory.changedProxies([proxy("a")], since: [:]).fingerprints
        let result = MenuItemFactory.changedProxies([proxy("a"), proxy("b")], since: baseline)
        #expect(result.changed.map(\.name) == ["b"])
        // The baseline follows the whole list, not just what changed, so the next
        // tick stays silent for both.
        #expect(MenuItemFactory.changedProxies([proxy("a"), proxy("b")],
                                               since: result.fingerprints).changed.isEmpty)
    }
}
