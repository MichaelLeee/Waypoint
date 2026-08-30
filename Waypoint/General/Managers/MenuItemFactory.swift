//
//  MenuItemFactory.swift
//  Waypoint
//

import Cocoa

@MainActor
final class MenuItemFactory {
    private static var cachedProxyData: WaypointProxyResp?

    nonisolated static let useViewToRenderProxy: Bool = AppDelegate.isAboveMacOS152

    // MARK: - Public

    static func refreshExistingMenuItems() {
        Task {
            let info = await ApiRequest.getMergedProxyData()
            if info?.proxiesMap.keys != cachedProxyData?.proxiesMap.keys {
                // force update menu
                refreshMenuItems(mergedData: info)
                return
            }

            for proxy in info?.proxies ?? [] {
                ProxyUpdateHub.shared.proxyDidUpdate(proxy)
            }
        }
    }

    static func recreateProxyMenuItems() {
        Task {
            let proxyInfo = await ApiRequest.getMergedProxyData()
            cachedProxyData = proxyInfo
            refreshMenuItems(mergedData: proxyInfo)
        }
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
        let startIndex = app.statusMenu.items.firstIndex(of: app.separatorLineTop)! + 1
        let endIndex = app.statusMenu.items.firstIndex(of: app.sepatatorLineEndProxySelect)!
        app.sepatatorLineEndProxySelect.isHidden = menus.isEmpty
        for _ in 0 ..< endIndex - startIndex {
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
            let success = await ApiRequest.updateProxyGroup(group: proxyGroup, selectProxy: proxyName)
            guard success else { return }
            for items in sender.menu?.items ?? [NSMenuItem]() {
                items.state = .off
            }
            sender.state = .on
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
