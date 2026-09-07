//
//  ApiURLDerivation.swift
//  WaypointNetworking
//  Pure derivation of the mihomo REST/WebSocket base URLs from an optional
//  override URL and the configured port.
//

import Foundation

public enum WaypointApiURL {
    /// REST base URL: the override verbatim, or the local mixed API port.
    public static func httpURL(overrideApiURL: URL?, apiPort: String) -> String {
        if let override = overrideApiURL {
            return override.absoluteString
        }
        return "http://127.0.0.1:\(apiPort)"
    }

    /// WebSocket base URL: ws, or wss when the override is https. An override
    /// that URLComponents cannot round-trip yields "" (matches legacy behavior
    /// the stream-connect callers treat as invalid).
    public static func webSocketURL(overrideApiURL: URL?, apiPort: String) -> String {
        if let override = overrideApiURL, var comp = URLComponents(url: override, resolvingAgainstBaseURL: true) {
            if comp.scheme == "https" {
                comp.scheme = "wss"
            } else {
                comp.scheme = "ws"
            }
            return comp.url?.absoluteString ?? ""
        }
        return "ws://127.0.0.1:\(apiPort)"
    }
}
