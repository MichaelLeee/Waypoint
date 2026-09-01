//
//  Logger.swift
//  Waypoint
//

import Foundation
import os

// @unchecked: file writes are serialized by the private logger queue; log()
// is called from any thread by design.
class Logger: @unchecked Sendable {
    static let shared = Logger()
    private static let system = os.Logger(subsystem: "org.waypnt.waypoint", category: "app")
    private static let queue = DispatchQueue(label: "org.waypnt.waypoint.logger")
    nonisolated(unsafe) private static var minLevel = ConfigManager.selectLoggingApiLevel

    private let logsDirectory: String
    private var currentFileHandle: FileHandle?
    private var currentFileName: String = ""

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waypoint/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logsDirectory = dir.path
        pruneOldLogs()
        openLogFile()
    }

    static func setLevel(_ level: WaypointLogLevel) {
        queue.sync { minLevel = level }
    }

    static func log(_ msg: String, level: WaypointLogLevel = .info, file: String = #file, function: String = #function) {
        queue.async {
            guard isEnabled(level) else { return }
            let line = "[\(level.rawValue)] \((file as NSString).lastPathComponent) \(function) \(msg)"
            switch level {
            case .debug: system.debug("\(line, privacy: .public)")
            case .info: system.info("\(line, privacy: .public)")
            case .warning, .unknow: system.notice("\(line, privacy: .public)")
            case .error: system.error("\(line, privacy: .public)")
            case .silent: return
            }
            shared.appendToFile(line)
        }
    }

    private static func isEnabled(_ level: WaypointLogLevel) -> Bool {
        switch (minLevel, level) {
        case (_, .silent):
            return false
        case (.silent, _):
            return false
        case (.debug, _):
            return true
        case (.info, .debug):
            return false
        case (.warning, .debug), (.warning, .info):
            return false
        case (.error, .debug), (.error, .info), (.error, .warning):
            return false
        default:
            return true
        }
    }

    func logFilePath() -> String {
        return Self.queue.sync { currentLogFilePath() }
    }

    func logFolder() -> String {
        return logsDirectory
    }

    // File management below runs on Logger.queue.

    private func currentLogFilePath() -> String {
        let name = logFileName(Date())
        let path = (logsDirectory as NSString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: path) ? path : ""
    }

    private func logFileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return "waypoint-\(formatter.string(from: date)).log"
    }

    private func openLogFile() {
        let name = logFileName(Date())
        guard name != currentFileName else { return }
        currentFileHandle?.closeFile()
        currentFileHandle = nil
        currentFileName = name
        let path = (logsDirectory as NSString).appendingPathComponent(name)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        currentFileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        if let handle = currentFileHandle {
            _ = try? handle.seekToEnd()
        }
    }

    private func appendToFile(_ line: String) {
        openLogFile()
        guard let handle = currentFileHandle, let data = "\(line)\n".data(using: .utf8) else { return }
        try? handle.write(contents: data)
    }

    private func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDirectory).sorted() else { return }
        for name in files.dropLast(3) where name.hasPrefix("waypoint-") && name.hasSuffix(".log") {
            try? fm.removeItem(atPath: (logsDirectory as NSString).appendingPathComponent(name))
        }
    }
}
