//
//  HTTPWire.swift
//  WaypointMitmEngine
//  Minimal HTTP/1.1 wire helpers shared by the head parser and the relay
//  pump. Operates on raw bytes; header blocks are ISO Latin-1 per RFC 9110.
//

import Foundation

enum HTTPWire {
    static let crlfcrlf: [UInt8] = Array("\r\n\r\n".utf8)
    static let crlf: [UInt8] = Array("\r\n".utf8)

    /// First line of a head block ("METHOD target HTTP/x.y").
    static func requestLine(of bytes: [UInt8]) -> [UInt8] {
        guard let newline = bytes.firstRange(of: crlf) else { return bytes }
        return Array(bytes[..<newline.lowerBound])
    }

    /// Value of the named header in a full head block; nil when absent.
    static func headerValue(in bytes: [UInt8], name: String) -> String? {
        guard let text = String(bytes: bytes, encoding: .isoLatin1) else { return nil }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            else { continue }
            return String(fields[1])
        }
        return nil
    }

    /// Parses "host[:port]" (also accepts userinfo and a scheme prefix),
    /// trimming surrounding brackets/whitespace. Port defaults to `defaultPort`.
    static func parseAuthority(_ authority: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        var text = authority.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let atSign = text.lastIndex(of: "@") {
            text = String(text[text.index(after: atSign)...])
        }
        if text.lowercased().hasPrefix("http://") {
            text = String(text.dropFirst("http://".count))
        }
        let cleaned = text.split(separator: "/").first.map(String.init) ?? text
        guard !cleaned.isEmpty else { return nil }
        if let colon = cleaned.firstIndex(of: ":"), !cleaned.hasSuffix(":") {
            let maybePort = UInt16(cleaned[cleaned.index(after: colon)...])
            let hostPart = String(cleaned[..<colon]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let portNumber = maybePort {
                return (hostPart.isEmpty ? "" : hostPart, portNumber)
            }
        }
        let hostPart = cleaned.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (hostPart, defaultPort)
    }

    /// Applies header rewrite rules to a complete header block: matching
    /// rules first remove every existing occurrence of their field, then
    /// append the replacement unless the rule's value is empty (removal).
    static func rewrittenHeaderBlock(_ block: [UInt8], rules: [MitmRule]) -> [UInt8] {
        guard let text = String(bytes: block, encoding: .isoLatin1) else { return block }
        var lines = text.components(separatedBy: "\r\n")
        guard lines.count > 1 else { return block }

        // Splitting a complete head block leaves trailing empty lines that
        // encode the final "\r\n\r\n"; strip them so appended rules land
        // inside the header section and the terminator is emitted exactly once.
        while lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }

        for rule in rules where !rule.headerKey.isEmpty {
            let prefix = "\(rule.headerKey.lowercased()):"
            for index in lines.indices.reversed()
            where index != lines.startIndex && lines[index].lowercased().hasPrefix(prefix) {
                lines.removeSubrange(index ... index)
            }
            if !rule.headerValue.isEmpty {
                lines.append("\(rule.headerKey): \(rule.headerValue)")
            }
        }
        let rebuilt = lines.joined(separator: "\r\n") + "\r\n\r\n"
        return Array(rebuilt.utf8)
    }
}
