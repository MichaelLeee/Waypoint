//
//  AppDelegate+Menu.swift
//  Waypoint
//
//  Programmatic menu construction (previously Main.storyboard).
//

import Cocoa

extension AppDelegate {
    // MARK: Menus

    func setupMenus() {
        NSApp.mainMenu = makeMainMenu()
        statusMenu = makeStatusMenu()
        statusMenu.delegate = self
    }

    @objc private func performEditAction(_ sender: NSMenuItem) {
        guard let actionName = sender.representedObject as? String else { return }
        NSApp.sendAction(Selector(actionName), to: nil, from: sender)
    }

    /// SwiftUI sheets swallow ⌘-based Edit key equivalents before the main
    /// menu is consulted (the context menu still works, but ⌘V/C/X/A/Z do
    /// nothing). Intercept them locally and forward to the key window's field
    /// editor; pass everything else through untouched.
    func setupEditShortcutMonitor() {
        editShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]) == .command,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let actionName: String?
            switch (key, event.modifierFlags.contains(.shift)) {
            case ("v", false): actionName = "paste:"
            case ("c", false): actionName = "copy:"
            case ("x", false): actionName = "cut:"
            case ("a", false): actionName = "selectAll:"
            case ("z", false): actionName = "undo:"
            case ("z", true): actionName = "redo:"
            default: actionName = nil
            }
            guard let actionName,
                  let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                  textView.isEditable else { return event }
            NSApp.sendAction(Selector(actionName), to: textView, from: event)
            return nil
        }
    }

    private func item(_ title: String,
                      action: Selector? = nil,
                      key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(title, comment: ""),
                              action: action,
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if action != nil {
            item.target = self
        }
        return item
    }

    /// The hidden application menu, required so text fields in the SwiftUI
    /// windows keep standard Edit shortcuts (copy/paste/undo, ⌘W ...).
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Waypoint")
        appMenu.addItem(withTitle: NSLocalizedString("Quit Waypoint", comment: ""),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        // SwiftUI text fields (notably inside sheets) are invisible to menu
        // validation, which leaves standard responder-chain items disabled and
        // their key equivalents (⌘V etc.) dead. Keep the items force-enabled
        // and forward to the responder chain explicitly on activation instead.
        editMenu.autoenablesItems = false
        let editActions: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            (NSLocalizedString("Undo", comment: ""), Selector(("undo:")), "z", .command),
            (NSLocalizedString("Redo", comment: ""), Selector(("redo:")), "z", [.command, .shift]),
            (NSLocalizedString("Cut", comment: ""), #selector(NSText.cut(_:)), "x", .command),
            (NSLocalizedString("Copy", comment: ""), #selector(NSText.copy(_:)), "c", .command),
            (NSLocalizedString("Paste", comment: ""), #selector(NSText.paste(_:)), "v", .command),
            (NSLocalizedString("Delete", comment: ""), #selector(NSText.delete(_:)), "", .command),
            (NSLocalizedString("Select All", comment: ""), #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, modifiers) in editActions {
            let item = NSMenuItem(title: title,
                                  action: #selector(performEditAction(_:)),
                                  keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.representedObject = NSStringFromSelector(action)
            item.target = self
            editMenu.addItem(item)
        }
        editMenu.addItem(.separator())
        let findItem = NSMenuItem()
        editMenu.addItem(findItem)
        let findMenu = NSMenu(title: NSLocalizedString("Find", comment: ""))
        let findSubItems: [(String, Int, String, NSEvent.ModifierFlags)] = [
            (NSLocalizedString("Find…", comment: ""), 1, "f", .command),
            (NSLocalizedString("Find and Replace…", comment: ""), 12, "f", [.command, .option]),
            (NSLocalizedString("Find Next", comment: ""), 2, "g", .command),
            (NSLocalizedString("Find Previous", comment: ""), 3, "G", .command),
            (NSLocalizedString("Use Selection for Find", comment: ""), 7, "e", .command),
            (NSLocalizedString("Jump to Selection", comment: ""), -1, "j", .command),
        ]
        for (title, tag, key, modifiers) in findSubItems {
            let sub = NSMenuItem(title: title,
                                 action: tag == -1
                                     ? #selector(NSResponder.centerSelectionInVisibleArea(_:))
                                     // performFindPanelAction is an informal AppKit action with no Swift declaration.
                                     : Selector(("performFindPanelAction:")),
                                 keyEquivalent: key)
            sub.tag = tag
            sub.keyEquivalentModifierMask = modifiers
            findMenu.addItem(sub)
        }
        findItem.submenu = findMenu
        editMenu.addItem(withTitle: NSLocalizedString("Close", comment: ""),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = editMenu

        return mainMenu
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        // Manual enable/disable control (Dashboard etc.); display-only items
        // are disabled explicitly below.
        menu.autoenablesItems = false

        proxyModeMenuItem = item("API Connect Error")
        let modeMenu = NSMenu()
        proxyModeGlobalMenuItem = item("Global",
                                       action: #selector(actionSwitchProxyMode(_:)),
                                       key: "g",
                                       modifiers: .option)
        proxyModeRuleMenuItem = item("Rule",
                                     action: #selector(actionSwitchProxyMode(_:)),
                                     key: "r",
                                     modifiers: .option)
        proxyModeDirectMenuItem = item("Direct",
                                       action: #selector(actionSwitchProxyMode(_:)),
                                       key: "d",
                                       modifiers: .option)
        modeMenu.addItem(proxyModeGlobalMenuItem)
        modeMenu.addItem(proxyModeRuleMenuItem)
        modeMenu.addItem(proxyModeDirectMenuItem)
        proxyModeMenuItem.submenu = modeMenu
        proxyModeMenuItem.isEnabled = false
        menu.addItem(proxyModeMenuItem)

        separatorLineTop = .separator()
        menu.addItem(separatorLineTop)
        sepatatorLineEndProxySelect = .separator()
        menu.addItem(sepatatorLineEndProxySelect)

        proxySettingMenuItem = item("Set as system proxy",
                                    action: #selector(actionSetSystemProxy(_:)),
                                    key: "s")
        menu.addItem(proxySettingMenuItem)

        enhanceTunModeMenuItem = item("Enhanced Mode",
                                      action: #selector(actionEnhanceTunMode(_:)),
                                      key: "e")
        menu.addItem(enhanceTunModeMenuItem)

        copyExportCommandMenuItem = item("Copy shell command",
                                         action: #selector(actionCopyExportCommand(_:)),
                                         key: "c")
        menu.addItem(copyExportCommandMenuItem)

        copyExportCommandExternalMenuItem = item("Copy shell command (External IP)",
                                                 action: #selector(actionCopyExportCommand(_:)),
                                                 key: "c",
                                                 modifiers: [.command, .option])
        copyExportCommandExternalMenuItem.isAlternate = true
        menu.addItem(copyExportCommandExternalMenuItem)

        menu.addItem(.separator())

        autoStartMenuItem = item("Start at login",
                                 action: #selector(actionStartAtLogin(_:)))
        menu.addItem(autoStartMenuItem)

        showNetSpeedIndicatorMenuItem = item("Show network indicator",
                                             action: #selector(actionShowNetSpeedIndicator(_:)))
        menu.addItem(showNetSpeedIndicatorMenuItem)

        allowFromLanMenuItem = item("Allow connect from Lan",
                                    action: #selector(actionAllowFromLan(_:)))
        menu.addItem(allowFromLanMenuItem)

        menu.addItem(.separator())

        menu.addItem(item("Benchmark", action: #selector(actionSpeedTest(_:)), key: "t"))

        dashboardMenuItem = item("Dashboard", action: #selector(actionDashboard(_:)), key: "d")
        dashboardMenuItem.isEnabled = false
        menu.addItem(dashboardMenuItem)

        connectionsMenuItem = item("Connection Details",
                                   action: #selector(actionConnections(_:)),
                                   key: "d",
                                   modifiers: [.command, .shift])
        menu.addItem(connectionsMenuItem)

        menu.addItem(.separator())

        let configsItem = item("Configs")
        let configsMenu = NSMenu()
        configSeparatorLine = .separator()
        configsMenu.addItem(configSeparatorLine)
        configsMenu.addItem(item("Open config folder",
                                 action: #selector(openConfigFolder(_:)),
                                 key: "o"))
        configsMenu.addItem(item("Reload config",
                                 action: #selector(actionUpdateConfig(_:)),
                                 key: "r"))
        configsMenu.addItem(item("Update external resources",
                                 action: #selector(actionUpdateExternalResource(_:)),
                                 key: "u",
                                 modifiers: [.command, .shift]))

        let remoteConfigItem = item("Remote config")
        let remoteConfigMenu = NSMenu()
        remoteConfigMenu.addItem(item("Manage",
                                      action: #selector(actionShowRemoteConfigManager(_:)),
                                      key: "m"))
        remoteConfigMenu.addItem(item("Update",
                                      action: #selector(actionUpdateRemoteConfig(_:)),
                                      key: "u"))
        remoteConfigAutoupdateMenuItem = item("Auto Update",
                                              action: #selector(actionAutoUpdateRemoteConfig(_:)))
        remoteConfigMenu.addItem(remoteConfigAutoupdateMenuItem)
        remoteConfigMenu.addItem(item("Set update interval",
                                      action: #selector(actionSetUpdateInterval(_:))))
        remoteConfigItem.submenu = remoteConfigMenu
        configsMenu.addItem(remoteConfigItem)

        let remoteControlItem = item("Remote controller")
        let remoteControlMenu = NSMenu()
        externalControlSeparator = .separator()
        remoteControlMenu.addItem(externalControlSeparator)
        remoteControlMenu.addItem(item(" Manage",
                                       action: #selector(actionShowExternalControlManager(_:))))
        remoteControlItem.submenu = remoteControlMenu
        configsMenu.addItem(remoteControlItem)

        configsItem.submenu = configsMenu
        menu.addItem(configsItem)

        menu.addItem(item("Settings", action: #selector(actionMoreSetting(_:))))

        let helpItem = item("Help")
        let helpMenu = NSMenu()
        helpMenu.addItem(item("About", action: #selector(actionShowAbout(_:))))
        checkForUpdateMenuItem = item("Check Update")
        helpMenu.addItem(checkForUpdateMenuItem)
        logLevelMenuItem = item("Log level")
        let logLevelMenu = NSMenu()
        for level in ["ERROR", "WARNING", "INFO", "DEBUG", "SILENT"] {
            logLevelMenu.addItem(item(level, action: #selector(actionSetLogLevel(_:))))
        }
        logLevelMenuItem.submenu = logLevelMenu
        helpMenu.addItem(logLevelMenuItem)
        helpMenu.addItem(item("Show Log", action: #selector(actionShowLog(_:)), key: "l"))
        let portsItem = item("Ports")
        let portsMenu = NSMenu()
        httpPortMenuItem = item("http port:")
        socksPortMenuItem = item("socks port:")
        apiPortMenuItem = item("api port:")
        ipMenuItem = item("IP:")
        for portItem in [httpPortMenuItem, socksPortMenuItem, apiPortMenuItem, ipMenuItem] {
            portItem?.isEnabled = false
            if let portItem {
                portsMenu.addItem(portItem)
            }
        }
        portsItem.submenu = portsMenu
        helpMenu.addItem(portsItem)
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(item("Quit", action: #selector(actionQuit(_:)), key: "q"))

        return menu
    }
}
