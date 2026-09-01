//
//  ICloudManager.swift
//  Waypoint
//

import Cocoa
import Combine

// @unchecked: instance state is confined to the main thread plus the
// serialized org.waypnt.icloud queue; the published subject is thread-safe.
class ICloudManager: @unchecked Sendable {
    static let shared = ICloudManager()
    private let queue = DispatchQueue(label: "org.waypnt.icloud")
    private var metaQuery: NSMetadataQuery?
    private var enableMenuItem: NSMenuItem?
    private(set) var icloudAvailable = false {
        didSet { useiCloud.send(userEnableiCloud && icloudAvailable) }
    }

    private var cancellables = Set<AnyCancellable>()

    // Thread-safe: read from background queues (RemoteConfigManager) and MainActor alike.
    let useiCloud = CurrentValueSubject<Bool, Never>(false)

    var userEnableiCloud: Bool = Persistence.userEnableiCloud {
        didSet {
            Persistence.userEnableiCloud = userEnableiCloud
            useiCloud.send(userEnableiCloud && icloudAvailable)
        }
    }

    func setup() {
        addNotification()
        useiCloud
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.checkiCloud()
            }
            .store(in: &cancellables)

        icloudAvailable = isICloudAvailable()
        useiCloud.send(userEnableiCloud && icloudAvailable)
    }

    func getConfigFilesList(configs: @escaping (([String]) -> Void)) {
        getUrl { url in
            guard let url = url,
                  let fileURLs = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                configs([])
                return
            }
            let list = fileURLs
                .filter { String($0.split(separator: ".").last ?? "") == "yaml" }
                .map { $0.split(separator: ".").dropLast().joined(separator: ".") }
            configs(list)
        }
    }

    private func checkiCloud() {
        getUrl { url in
            guard let url = url else {
                self.icloudAvailable = false
                return
            }
            let files = try? FileManager.default.contentsOfDirectory(atPath: url.path)
            if files?.isEmpty == true {
                let path = Bundle.main.path(forResource: "sampleConfig", ofType: "yaml")!
                try? FileManager.default.copyItem(atPath: path, toPath: kDefaultConfigFilePath)
                try? FileManager.default.copyItem(atPath: Bundle.main.path(forResource: "sampleConfig", ofType: "yaml")!, toPath: url.appendingPathComponent("config.yaml").path)
            }
        }
    }

    private func isICloudAvailable() -> Bool {
        return FileManager.default.ubiquityIdentityToken != nil
    }

    func getUrl(complete: ((URL?) -> Void)? = nil) {
        // The completion is always invoked on the main queue; mark unchecked
        // so it can cross into the @Sendable queue closures.
        nonisolated(unsafe) let complete = complete
        queue.async {
            guard var url = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                DispatchQueue.main.async {
                    complete?(nil)
                }
                return
            }
            url.appendPathComponent("Documents")
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
                }
                DispatchQueue.main.async {
                    complete?(url)
                }
            } catch let err {
                Logger.log("\(err)")
                DispatchQueue.main.async {
                    complete?(nil)
                }
                return
            }
        }
    }

    private func addNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(iCloudAccountAvailabilityChanged), name: NSNotification.Name.NSUbiquityIdentityDidChange, object: nil)
    }

    @objc func iCloudAccountAvailabilityChanged() {
        icloudAvailable = isICloudAvailable()
    }
}
