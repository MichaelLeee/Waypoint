//
//  MenuItemFactory.swift
//  Waypoint
//

import WaypointNetworking
import Cocoa
import WaypointCore

@MainActor
final class MenuItemFactory {
    private static var cachedProxyData: WaypointProxyResp?

    /// What the menu last drew for each proxy, keyed by name. The menu is
    /// refreshed on a timer while it is open, and publishing an unchanged model
    /// makes every row rebuild its text — and every group row rebuild its
    /// selected-node label — once a second for no reason.
    private static var publishedFingerprints: [String: String] = [:]

    /// Skipped refresh already running; see `refreshExistingMenuItems`.
    private static var refreshInFlight = false

    nonisolated static let useViewToRenderProxy: Bool = AppDelegate.isAboveMacOS152

    // MARK: - Public

    /// Re-reads the core's proxy state and pushes what changed to the rows that
    /// are on screen. Called when the menu opens and on a timer while it is
    /// open, so a selection made anywhere else — an auto-selecting group, the
    /// dashboard, another client, a Shortcut — shows up without reopening it.
    static func refreshExistingMenuItems() {
        // A tick whose predecessor is still in flight is dropped: a slow or
        // stuck core must not accumulate overlapping requests while the menu
        // sits open.
        guard !refreshInFlight else { return }
        refreshInFlight = true
        Task {
            defer { refreshInFlight = false }
            let info = await ApiClient.shared.getMergedProxyData()
            if info?.proxiesMap.keys != cachedProxyData?.proxiesMap.keys {
                // force update menu
                refreshMenuItems(mergedData: info)
                return
            }

            let (changed, fingerprints) = changedProxies(info?.proxies ?? [],
                                                         since: publishedFingerprints)
            publishedFingerprints = fingerprints
            for proxy in changed {
                ProxyUpdateHub.shared.proxyDidUpdate(proxy)
            }
        }
    }

    static func recreateProxyMenuItems() {
        Task {
            let proxyInfo = await ApiClient.shared.getMergedProxyData()
            refreshMenuItems(mergedData: proxyInfo)
        }
    }

    /// The proxies whose drawn state differs from `previous`, together with the
    /// fingerprint map to compare against next time. Kept separate from the
    /// I/O so the change detection can be tested without a menu or a core.
    static func changedProxies(_ proxies: [WaypointProxy],
                               since previous: [String: String]) -> (changed: [WaypointProxy], fingerprints: [String: String]) {
        let fingerprints = fingerprintMap(of: proxies)
        let changed = proxies.filter { previous[$0.name] != fingerprints[$0.name] }
        return (changed, fingerprints)
    }

    /// Fingerprints for every proxy, for use as the new baseline.
    static func fingerprintMap(of proxies: [WaypointProxy]) -> [String: String] {
        var map = [String: String](minimumCapacity: proxies.count)
        for proxy in proxies {
            map[proxy.name] = fingerprint(of: proxy)
        }
        return map
    }

    /// Everything the rows and their history submenus draw for one proxy: the
    /// group's selected member, the alive flag, and the newest delay sample
    /// (including how many samples there are, which is what the history submenu
    /// lists).
    private static func fingerprint(of proxy: WaypointProxy) -> String {
        let latest = proxy.history.last
        return [
            proxy.now ?? "-",
            proxy.alive.map { $0 ? "alive" : "dead" } ?? "-",
            latest.map { "\($0.delay)/\($0.meanDelay.map(String.init) ?? "-")" } ?? "-",
            String(proxy.history.count),
        ].joined(separator: "|")
    }

    static func refreshMenuItems(mergedData proxyInfo: WaypointProxyResp?) {
        let leftPadding = AppDelegate.shared.hasMenuSelected()
        guard let proxyInfo = proxyInfo else { return }
        var menuItems = [NSMenuItem]()
        for proxy in proxyInfo.proxyGroups {
            var menu: NSMenuItem?
            switch proxy.type {
            case .select: menu = generateSelectorMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo, leftPadding: leftPadding)
            case .urltest, .fallback: menu = generateUrlTestFallBackMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo, leftPadding: leftPadding)
            case .loadBalance:
                menu = generateLoadBalanceMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo, leftPadding: leftPadding)
            case .relay:
                menu = generateListOnlyMenuItem(proxyGroup: proxy, proxyInfo: proxyInfo)
            default: continue
            }

            if let menu = menu {
                menuItems.append(menu)
                menu.isEnabled = true
            }
        }
        let items = Array(menuItems.reversed())
        updateProxyList(withMenus: items)
        // These rows were just built from this data, so it is the baseline for
        // "what changed": without recording it here, every later refresh sees a
        // proxy-name set that never matches the cached one and rebuilds the whole
        // menu again — every time the menu opens.
        cachedProxyData = proxyInfo
        publishedFingerprints = fingerprintMap(of: proxyInfo.proxies)
    }

    static func generateSwitchConfigMenuItems(complete: @escaping (([NSMenuItem]) -> Void)) {
        let generateMenuItem: ((String) -> NSMenuItem) = {
            config in
            let item = NSMenuItem(title: config, action: #selector(MenuItemFactory.actionSelectConfig(sender:)), keyEquivalent: "")
            item.target = MenuItemFactory.self
            item.state = ConfigManager.selectConfigName == config ? .on : .off
            return item
        }

        if RemoteControlManager.selectConfig != nil {
            complete([])
            return
        }

        if ICloudManager.shared.useiCloud.value {
            ICloudManager.shared.getConfigFilesList {
                complete($0.map { generateMenuItem($0) })
            }
        } else {
            complete(ConfigManager.getConfigFilesList().map { generateMenuItem($0) })
        }
    }

    // MARK: - Private

    // MARK: Updaters

    static func updateProxyList(withMenus menus: [NSMenuItem]) {
        let app = AppDelegate.shared
        // The two separators bracket the proxy rows. If a rebuild ever leaves
        // one out of the menu, or leaves them out of order, the old forced
        // unwrap and the negative row count each trapped; skip instead.
        guard let top = app.statusMenu.items.firstIndex(of: app.separatorLineTop),
              let end = app.statusMenu.items.firstIndex(of: app.sepatatorLineEndProxySelect),
              end >= top else {
            Logger.log("updateProxyList: proxy separators missing from the menu", level: .error)
            return
        }
        let startIndex = top + 1
        app.sepatatorLineEndProxySelect.isHidden = menus.isEmpty
        // Clamped so adjacent separators (zero existing rows) cannot form the
        // negative range `startIndex ..< end`, which would trap.
        for _ in 0 ..< max(0, end - startIndex) {
            app.statusMenu.removeItem(at: startIndex)
        }
        for each in menus {
            app.statusMenu.insertItem(each, at: startIndex)
        }
    }

    // MARK: Generators

    private static func generateSelectorMenuItem(proxyGroup: WaypointProxy,
                                                 proxyInfo: WaypointProxyResp,
                                                 leftPadding: Bool) -> NSMenuItem? {
        let proxyMap = proxyInfo.proxiesMap

        let isGlobalMode = ConfigManager.shared.currentConfig?.mode == .global
        if !isGlobalMode {
            if proxyGroup.name == "GLOBAL" { return nil }
        }

        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        let selectedName = proxyGroup.now ?? ""
        if !Settings.disableShowCurrentProxyInMenu {
            menu.view = ProxyGroupMenuItemView(group: proxyGroup.name, targetProxy: selectedName, hasLeftPadding: leftPadding)
        }
        let submenu = ProxyGroupMenu(title: proxyGroup.name)
        let speedtestAble = proxyInfo.speedtestAbleItems(for: proxyGroup.name)

        for proxy in proxyGroup.all ?? [] {
            guard let proxyModel = proxyMap[proxy] else { continue }
            let proxyItem = ProxyMenuItem(proxy: proxyModel,
                                          group: proxyGroup,
                                          action: #selector(MenuItemFactory.actionSelectProxy(sender:)),
                                          isSpeedTestable: !speedtestAble.isEmpty,
                                          maxNameLength: ProxyNameMeasurer.maxProxyNameLength(in: proxyGroup.all))
            proxyItem.target = MenuItemFactory.self
            submenu.add(delegate: proxyItem)
            submenu.addItem(proxyItem)
        }

        if !speedtestAble.isEmpty && useViewToRenderProxy {
            submenu.minimumWidth = ProxyNameMeasurer.maxProxyNameLength(in: proxyGroup.all) + ProxyItemView.fixedPlaceHolderWidth
        }

        addSpeedTestMenuItem(submenu, proxyGroup: proxyGroup, proxyInfo: proxyInfo)
        menu.submenu = submenu
        return menu
    }

    private static func generateUrlTestFallBackMenuItem(proxyGroup: WaypointProxy,
                                                        proxyInfo: WaypointProxyResp,
                                                        leftPadding: Bool) -> NSMenuItem? {
        let proxyMap = proxyInfo.proxiesMap
        let selectedName = proxyGroup.now ?? ""
        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        if !Settings.disableShowCurrentProxyInMenu {
            menu.view = ProxyGroupMenuItemView(group: proxyGroup.name, targetProxy: selectedName, hasLeftPadding: leftPadding)
        }
        let submenu = NSMenu(title: proxyGroup.name)

        for proxyName in proxyGroup.all ?? [] {
            guard let proxy = proxyMap[proxyName] else { continue }
            let proxyMenuItem = ProxyMenuItem(proxy: proxy, group: proxyGroup, action: #selector(empty), simpleItem: true)
            proxyMenuItem.target = MenuItemFactory.self
            if proxy.name == selectedName {
                proxyMenuItem.state = .on
            }

            proxyMenuItem.submenu = ProxyDelayHistoryMenu(proxy: proxy)

            submenu.addItem(proxyMenuItem)
        }
        addSpeedTestMenuItem(submenu, proxyGroup: proxyGroup, proxyInfo: proxyInfo)
        menu.submenu = submenu
        return menu
    }

    private static func addSpeedTestMenuItem(_ menu: NSMenu, proxyGroup: WaypointProxy, proxyInfo: WaypointProxyResp) {
        let testableItems = proxyInfo.speedtestAbleItems(for: proxyGroup.name)
        guard !testableItems.isEmpty else { return }
        let speedTestItem = ProxyGroupSpeedTestMenuItem(group: proxyGroup, testableItems: testableItems)
        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: 0)
        menu.insertItem(speedTestItem, at: 0)
        (menu as? ProxyGroupMenu)?.add(delegate: speedTestItem)
    }

    private static func generateLoadBalanceMenuItem(proxyGroup: WaypointProxy, proxyInfo: WaypointProxyResp, leftPadding: Bool) -> NSMenuItem? {
        let proxyMap = proxyInfo.proxiesMap

        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        if !Settings.disableShowCurrentProxyInMenu {
            menu.view = ProxyGroupMenuItemView(group: proxyGroup.name, targetProxy: NSLocalizedString("Load Balance", comment: ""), hasLeftPadding: leftPadding, observeUpdate: false)
        }
        let submenu = ProxyGroupMenu(title: proxyGroup.name)
        let speedtestAble = proxyInfo.speedtestAbleItems(for: proxyGroup.name)

        for proxy in proxyGroup.all ?? [] {
            guard let proxyModel = proxyMap[proxy] else { continue }
            let proxyItem = ProxyMenuItem(proxy: proxyModel,
                                          group: proxyGroup,
                                          action: #selector(empty),
                                          isSpeedTestable: !speedtestAble.isEmpty,
                                          maxNameLength: ProxyNameMeasurer.maxProxyNameLength(in: proxyGroup.all))
            proxyItem.target = MenuItemFactory.self
            submenu.add(delegate: proxyItem)
            submenu.addItem(proxyItem)
        }
        if !speedtestAble.isEmpty && useViewToRenderProxy {
            submenu.minimumWidth = ProxyNameMeasurer.maxProxyNameLength(in: proxyGroup.all) + ProxyItemView.fixedPlaceHolderWidth
        }
        addSpeedTestMenuItem(submenu, proxyGroup: proxyGroup, proxyInfo: proxyInfo)
        menu.submenu = submenu

        return menu
    }

    private static func generateListOnlyMenuItem(proxyGroup: WaypointProxy, proxyInfo: WaypointProxyResp) -> NSMenuItem? {
        let menu = NSMenuItem(title: proxyGroup.name, action: nil, keyEquivalent: "")
        let submenu = ProxyGroupMenu(title: proxyGroup.name)
        let proxyMap = proxyInfo.proxiesMap

        for proxy in proxyGroup.all ?? [] {
            guard let proxyModel = proxyMap[proxy] else { continue }
            let proxyItem = ProxyMenuItem(proxy: proxyModel,
                                          group: proxyGroup,
                                          action: #selector(empty),
                                          simpleItem: true)
            proxyItem.target = MenuItemFactory.self
            submenu.add(delegate: proxyItem)
            submenu.addItem(proxyItem)
        }
        menu.submenu = submenu
        return menu
    }
}

// MARK: - Action

extension MenuItemFactory {
    @objc static func actionSelectProxy(sender: ProxyMenuItem) {
        guard let proxyGroup = sender.menu?.title else { return }
        let proxyName = sender.proxyName

        Task {
            let success = await ApiClient.shared.updateProxyGroup(group: proxyGroup, selectProxy: proxyName)
            guard success else { return }
            // Through the row's own update path, not by assigning `state`: on
            // this deployment target the rows render through a view, and a
            // view-backed menu item draws no state of its own, so setting it
            // left the checkmark on the previously selected node until the next
            // refresh came back.
            for item in sender.menu?.items ?? [NSMenuItem]() {
                (item as? ProxyMenuItem)?.updateSelected(item === sender)
            }
            // remember select proxy
            let newModel = SavedProxyModel(group: proxyGroup, selected: proxyName, config: ConfigManager.selectConfigName)
            ConfigManager.selectedProxyRecords.removeAll { model -> Bool in
                return model.key == newModel.key
            }
            ConfigManager.selectedProxyRecords.append(newModel)
            // terminal Connections for this group
            ConnectionManager.closeConnection(for: proxyGroup)
            // refresh menu items
            MenuItemFactory.refreshExistingMenuItems()
        }
    }

    @objc static func actionSelectConfig(sender: NSMenuItem) {
        let config = sender.title
        AppDelegate.shared.updateConfig(configName: config, showNotification: false) {
            err in
            if err == nil {
                ConnectionManager.closeAllConnection()
            }
        }
    }

    @objc static func empty() {}
}
