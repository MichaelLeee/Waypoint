//
//  MitmEngineTests.swift
//  WaypointCoreTests
//  Pure-logic coverage for the MITM engine: rule matching and the HTTP/1.1
//  wire helpers. The engine's I/O behaviour is exercised by the app itself.
//

import Testing
@testable import WaypointMitmEngine

@Suite("MITM rule matching")
struct MitmRuleTests {

    @Test("Dot-prefixed host matches the domain and every subdomain")
    func wildcardHost() {
        let rule = MitmRule(kind: .requestHeader, host: ".example.com", headerKey: "X-Test", headerValue: "1")
        #expect(rule.matches(host: "a.example.com"))
        #expect(rule.matches(host: "example.com"))
        #expect(!rule.matches(host: "badexample.com"))
        #expect(!rule.matches(host: "other.org"))
    }

    @Test("Exact host matches only itself")
    func exactHost() {
        let rule = MitmRule(kind: .reject, host: "ads.example.com", headerKey: "", headerValue: "")
        #expect(rule.matches(host: "ads.example.com"))
        #expect(!rule.matches(host: "cdn.ads.example.com"))
    }

    @Test("Matching is case-insensitive on both sides")
    func caseInsensitive() {
        let rule = MitmRule(kind: .reject, host: ".Example.COM", headerKey: "", headerValue: "")
        #expect(rule.matches(host: "WWW.EXAMPLE.COM"))
        #expect(rule.matches(host: "example.com"))
    }
}

@Suite("HTTP wire helpers")
struct HTTPWireTests {

    @Test("parseAuthority handles host, host:port, userinfo and absolute URLs")
    func parseAuthorityCases() {
        // Optional tuples have no direct literal comparison; assert per field.
        let simple = HTTPWire.parseAuthority("example.com", defaultPort: 443)
        #expect(simple?.host == "example.com")
        #expect(simple?.port == 443)

        let withPort = HTTPWire.parseAuthority("example.com:8443", defaultPort: 443)
        #expect(withPort?.host == "example.com")
        #expect(withPort?.port == 8443)

        let withUserinfo = HTTPWire.parseAuthority("user:pass@example.com:99", defaultPort: 80)
        #expect(withUserinfo?.host == "example.com")
        #expect(withUserinfo?.port == 99)

        let absolute = HTTPWire.parseAuthority("http://example.com/x", defaultPort: 80)
        #expect(absolute?.host == "example.com")
        #expect(absolute?.port == 80)

        #expect(HTTPWire.parseAuthority("", defaultPort: 80) == nil)
    }

    @Test("headerValue finds the named field and keeps later colons")
    func headerValue() {
        let head = Array("GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: t: v\r\n\r\n".utf8)
        #expect(HTTPWire.headerValue(in: head, name: "host") == " example.com")
        #expect(HTTPWire.headerValue(in: head, name: "user-agent") == " t: v")
        #expect(HTTPWire.headerValue(in: head, name: "Accept") == nil)
    }

    @Test("rewrittenHeaderBlock replaces existing field and appends once")
    func rewriteAppendsAndReplaces() {
        let block = Array("POST /x HTTP/1.1\r\nHost: e.com\r\nX-Old: a\r\nX-Old: b\r\n\r\n".utf8)
        let rules = [MitmRule(kind: .requestHeader, host: "*", headerKey: "X-Old", headerValue: "new")]
        let out = String(bytes: HTTPWire.rewrittenHeaderBlock(block, rules: rules), encoding: .isoLatin1)!
        #expect(out == "POST /x HTTP/1.1\r\nHost: e.com\r\nX-Old: new\r\n\r\n")
    }

    @Test("Empty rule value removes the field entirely")
    func rewriteRemoves() {
        let block = Array("GET / HTTP/1.1\r\nHost: e.com\r\nX-Trace: 1\r\n\r\n".utf8)
        let rules = [MitmRule(kind: .requestHeader, host: "*", headerKey: "X-Trace", headerValue: "")]
        let out = String(bytes: HTTPWire.rewrittenHeaderBlock(block, rules: rules), encoding: .isoLatin1)!
        #expect(out == "GET / HTTP/1.1\r\nHost: e.com\r\n\r\n")
    }

    @Test("Single-line block (no header section) is returned untouched")
    func incompleteBlock() {
        let block = Array("GET / HTTP/1.1".utf8)
        #expect(Array(HTTPWire.rewrittenHeaderBlock(block, rules: [])) == block)
    }
}
