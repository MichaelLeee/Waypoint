//
//  NSTableView+Reload.swift
//  Waypoint
//

import Cocoa

extension NSTableView {
    func reloadDataKeepingSelection() {
        let selectedRowIndexes = selectedRowIndexes
        reloadData()
        var indexs = IndexSet()
        for index in selectedRowIndexes {
            if index >= 0 && index <= numberOfRows {
                indexs.insert(index)
            }
        }
        selectRowIndexes(indexs, byExtendingSelection: false)
    }
}
