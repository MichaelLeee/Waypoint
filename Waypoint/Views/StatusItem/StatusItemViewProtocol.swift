//
//  StatusItemViewProtocol.swift
//  Waypoint Pro
//

import AppKit

@MainActor
protocol StatusItemViewProtocol: AnyObject {
    func updateViewStatus(enableProxy: Bool)
    func updateSpeedLabel(up: Int, down: Int)
    func showSpeedContainer(show: Bool)
}
