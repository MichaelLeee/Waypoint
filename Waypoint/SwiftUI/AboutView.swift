//
//  AboutView.swift
//  Waypoint
//  Replaces the storyboard About scene (AboutViewController).
//

import SwiftUI

struct AboutView: View {
    private let version = AppVersionUtil.currentVersion
    private let build = AppVersionUtil.currentBuild
    private let isBeta = AppVersionUtil.isBeta
    private let coreVersion = Bundle.main.infoDictionary?["coreVersion"] as? String ?? "unknown"
    private let commit = Bundle.main.infoDictionary?["gitCommit"] as? String ?? "unknown"
    private let branch = Bundle.main.infoDictionary?["gitBranch"] as? String ?? "unknown"
    private let buildTime = Bundle.main.infoDictionary?["buildTime"] as? String ?? "unknown"

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Waypoint")
                .font(.title2.bold())
            Text("Version: \(version) (\(build))\(isBeta ? " Beta" : "")")
                .font(.body)
            Text(coreVersion)
                .font(.body)
                .foregroundStyle(.secondary)
            Text("\(commit)-\(branch) \(buildTime)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 28) {
                Link("mihomo",
                     destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
                Link("Waypoint",
                     destination: URL(string: "https://github.com/MichaelLeee/Waypoint")!)
            }
            .font(.body)
        }
        .padding(24)
        .frame(width: 300)
    }

    private var appIcon: NSImage {
        if let icon = NSApp.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        return NSImage()
    }
}
