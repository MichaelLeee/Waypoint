//
//  RemoteConfigModel.swift
//  Waypoint
//

import Cocoa

// @unchecked: effectively main-thread confined; updateConfig only mutates it
// from MainActor.run hops.
class RemoteConfigModel: Codable, @unchecked Sendable {
    var url: String
    var name: String
    var updateTime: Date?
    var updating = false
    var isPlaceHolderName = false

    init(url: String, name: String, updateTime: Date? = nil) {
        self.url = url
        self.name = name
        self.updateTime = updateTime
    }

    private enum CodingKeys: String, CodingKey {
        case url, name, updateTime
    }

    func displayingTimeString() -> String {
        if updating { return NSLocalizedString("Updating", comment: "") }
        let dateFormater = DateFormatter()
        dateFormater.dateFormat = "MM-dd HH:mm"
        if let date = updateTime {
            return dateFormater.string(from: date)
        }
        return NSLocalizedString("Never", comment: "")
    }
}

extension RemoteConfigModel: Equatable {
    static func == (lhs: RemoteConfigModel, rhs: RemoteConfigModel) -> Bool {
        return lhs.name == rhs.name && lhs.url == rhs.url
    }
}
