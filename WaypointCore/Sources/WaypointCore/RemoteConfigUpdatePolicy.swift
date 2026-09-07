import Foundation

/// Decides whether a remote-config entry is due for an update check.
/// Extracted from RemoteConfigManager.updateCheck so the scheduling rules
/// are unit-testable without the manager's timers and side effects.
public enum RemoteConfigUpdatePolicy {
    /// A fresh entry is bypassed until `interval` has elapsed since its last
    /// update; an in-flight entry (`updating`) is never re-entered;
    /// `ignoreTimeLimit` (manual "update now") overrides the interval.
    public static func isDueForUpdate(updating: Bool,
                                      updateTime: Date?,
                                      now: Date,
                                      interval: TimeInterval,
                                      ignoreTimeLimit: Bool) -> Bool {
        if updating { return false }
        if ignoreTimeLimit { return true }
        let last = updateTime ?? Date(timeIntervalSince1970: 0)
        return now.timeIntervalSince(last) >= interval
    }
}

/// Validates and shapes the HTTP layer of a remote-config download.
/// The URLSession call itself stays app-side; only the pure decisions live here.
public enum RemoteConfigFetch {
    /// Builds the download request; nil when the configured URL is malformed.
    public static func request(urlString: String) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringCacheData
        return request
    }

    /// Returns the config text when the response is usable, otherwise nil
    /// (non-2xx status or non-UTF-8 body).
    public static func decodeResponse(statusCode: Int, data: Data) -> String? {
        guard (200 ... 299).contains(statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
