//
//  Combine+Ext.swift
//  Waypoint
//

import Combine
import Foundation

@available(macOS 10.15, *)
public extension Publisher where Failure == Never {
    func weakAssign<T: AnyObject>(
        to keyPath: ReferenceWritableKeyPath<T, Output>,
        on object: T
    ) -> AnyCancellable {
        sink { [weak object] value in
            object?[keyPath: keyPath] = value
        }
    }
}
