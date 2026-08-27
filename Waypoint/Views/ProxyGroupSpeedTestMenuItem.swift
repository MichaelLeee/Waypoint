//
//  ProxyGroupSpeedTestMenuItem.swift
//  Waypoint
//

import Carbon
import Cocoa

@MainActor
final class ProxyGroupSpeedTestMenuItem: NSMenuItem, @unchecked Sendable {
    let proxyGroup: WaypointProxy
    let testType: TestType

    init(group: WaypointProxy) {
        proxyGroup = group
        if group.type.isAutoGroup {
            testType = .reTest
        } else if group.type == .select {
            testType = .benchmark
        } else {
            testType = .unknown
        }

        super.init(title: NSLocalizedString("Benchmark", comment: ""), action: nil, keyEquivalent: "")
        target = self
        action = #selector(healthCheck)

        switch testType {
        case .benchmark:
            view = ProxyGroupSpeedTestMenuItemView(testType.title)
        case .reTest:
            title = testType.title
        case .unknown:
            assertionFailure()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func healthCheck() {
        guard testType == .reTest else { return }
        Task {
            await ApiRequest.healthCheck(proxy: proxyGroup.name)
            let proxyResp = await ApiRequest.getMergedProxyData()
            var providers = Set<WaypointProxyName>()
            proxyGroup.all?.compactMap {
                proxyResp?.proxiesMap[$0]?.enclosingProvider?.name
            }.forEach {
                providers.insert($0)
            }
            await withTaskGroup(of: Void.self) { taskGroup in
                for provider in providers {
                    taskGroup.addTask { await ApiRequest.healthCheck(proxy: provider) }
                }
            }
        }
        menu?.cancelTracking()
    }
}

extension ProxyGroupSpeedTestMenuItem: ProxyGroupMenuHighlightDelegate {
    // The @objc protocol requirement is nonisolated; this class is MainActor.
    // Menus call this on the main thread only.
    nonisolated func highlight(item: NSMenuItem?) {
        MainActor.assumeIsolated {
            (view as? ProxyGroupSpeedTestMenuItemView)?.isHighlighted = item == self
        }
    }
}

private class ProxyGroupSpeedTestMenuItemView: MenuItemBaseView {
    private let label: NSTextField

    init(_ title: String) {
        label = NSTextField(labelWithString: title)
        label.font = type(of: self).labelFont
        label.sizeToFit()
        let rect = NSRect(x: 0, y: 0, width: label.bounds.width + 40, height: 20)
        super.init(frame: rect, autolayout: false)
        addSubview(label)
        label.frame = NSRect(x: 20, y: 0, width: label.bounds.width, height: 20)
        label.textColor = NSColor.labelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var cells: [NSCell?] {
        return [label.cell]
    }

    override var labels: [NSTextField] {
        return [label]
    }

    override func didClickView() {
        startBenchmark()
    }

    private func startBenchmark() {
        guard let group = (enclosingMenuItem as? ProxyGroupSpeedTestMenuItem)?.proxyGroup
        else { return }

        var proxies = [WaypointProxyName]()
        var providers = Set<WaypointProviderName>()
        for testable in group.speedtestAble {
            switch testable {
            case let .provider(_, provider):
                providers.insert(provider)
            case let .proxy(name):
                proxies.append(name)
            }
        }

        label.stringValue = NSLocalizedString("Testing", comment: "")
        enclosingMenuItem?.isEnabled = false
        setNeedsDisplay()

        Task {
            await withTaskGroup(of: Void.self) { taskGroup in
                for proxyName in proxies {
                    taskGroup.addTask {
                        let delay = await ApiRequest.getProxyDelay(proxyName: proxyName)
                        let delayStr = delay == 0 ? NSLocalizedString("fail", comment: "") : "\(delay) ms"
                        NotificationCenter.default.post(name: .speedTestFinishForProxy,
                                                        object: nil,
                                                        userInfo: ["proxyName": proxyName, "delay": delayStr, "rawValue": delay])
                    }
                }
                for provider in providers {
                    taskGroup.addTask { await ApiRequest.healthCheck(proxy: provider) }
                }
            }
            guard let menu = enclosingMenuItem else { return }
            label.stringValue = menu.title
            menu.isEnabled = true
            setNeedsDisplay()
            if !providers.isEmpty {
                MenuItemFactory.refreshExistingMenuItems()
            }
        }
    }
}

extension ProxyGroupSpeedTestMenuItem {
    enum TestType {
        case benchmark
        case reTest
        case unknown

        var title: String {
            switch self {
            case .benchmark: return NSLocalizedString("Benchmark", comment: "")
            case .reTest: return NSLocalizedString("ReTest", comment: "")
            case .unknown: return ""
            }
        }
    }
}
