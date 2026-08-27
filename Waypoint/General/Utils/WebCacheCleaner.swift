//
//  WebCacheCleaner.swift
//  Waypoint
//

import WebKit

enum WebCacheCleaner {
    @MainActor static func clean() {
        URLCache.shared.removeAllCachedResponses()
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
        ]
        WKWebsiteDataStore.default()
            .removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: {})
    }
}
