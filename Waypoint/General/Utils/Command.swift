//
//  Command.swift
//  Waypoint
//

import Foundation

struct Command {
    let cmd: String
    let args: [String]

    func run() -> String {
        var output = ""

        let task = Process()
        task.launchPath = cmd
        task.arguments = args

        // NSTask raises an unrecoverable ObjC exception when the path is
        // missing or not executable; pre-check instead of trying to catch it.
        guard FileManager.default.isExecutableFile(atPath: cmd) else {
            Logger.log("command not accessible: \(cmd)", level: .warning)
            return ""
        }

        let outpipe = Pipe()
        task.standardOutput = outpipe

        task.launch()

        let outdata = outpipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if let string = String(data: outdata, encoding: .utf8) {
            output = string.trimmingCharacters(in: .newlines)
        }
        return output
    }
}
