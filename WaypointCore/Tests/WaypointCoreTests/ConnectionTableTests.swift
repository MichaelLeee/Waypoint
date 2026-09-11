import Foundation
import Testing
@testable import WaypointCore

private func conn(_ id: String,
                  host: String = "default.test",
                  chains: [String] = ["PROXY"],
                  rule: String = "MATCH",
                  processName: String? = nil,
                  start: Date = Date(timeIntervalSince1970: 0),
                  upload: Int = 0,
                  download: Int = 0) -> ConnectionRow {
    ConnectionRow(id: id,
                  host: host,
                  chains: chains,
                  rule: rule,
                  rulePayload: "",
                  network: "tcp",
                  type: "HTTP",
                  source: "127.0.0.1:1",
                  destinationIP: "1.2.3.4",
                  processName: processName,
                  start: start,
                  upload: upload,
                  download: download)
}

struct ConnectionTableTests {
    @Test func firstFrameReportsNoSpeed() {
        var table = ConnectionTable()
        table.merge([conn("a", upload: 1_000, download: 2_000)])
        #expect(table.rows.count == 1)
        #expect(table.rows[0].upload == 1_000)
        #expect(table.rows[0].uploadSpeed == 0)
        #expect(table.rows[0].downloadSpeed == 0)
    }

    @Test func laterFramesReportCounterDeltas() {
        var table = ConnectionTable()
        table.merge([conn("a", upload: 1_000, download: 2_000)])
        table.merge([conn("a", upload: 1_600, download: 2_050)])
        #expect(table.rows[0].uploadSpeed == 600)
        #expect(table.rows[0].downloadSpeed == 50)
        #expect(table.rows[0].upload == 1_600)
        #expect(table.rows[0].download == 2_050)
    }

    @Test func fieldsRefreshFromLaterFrames() {
        var table = ConnectionTable()
        table.merge([conn("a", rule: "MATCH")])
        table.merge([conn("a", rule: "DOMAIN-SUFFIX")])
        #expect(table.rows[0].rule == "DOMAIN-SUFFIX")
    }

    @Test func finishedRowKeepsTotalsAndDropsToZeroSpeed() {
        var table = ConnectionTable()
        table.merge([conn("a", upload: 1_000, download: 2_000)])
        table.merge([conn("a", upload: 1_600, download: 2_050)])
        table.merge([])
        #expect(table.rows.count == 1)
        #expect(table.rows[0].upload == 1_600)
        #expect(table.rows[0].uploadSpeed == 0)
        #expect(table.rows[0].downloadSpeed == 0)
        #expect(table.activeIDs.isEmpty)
    }

    @Test func activeIDsFollowTheLatestFrameOnly() {
        var table = ConnectionTable()
        table.merge([conn("a"), conn("b")])
        #expect(table.activeIDs == ["a", "b"])
        table.merge([conn("b")])
        #expect(table.activeIDs == ["b"])
    }

    @Test func rowsAreOrderedNewestFirst() {
        var table = ConnectionTable()
        let base = Date(timeIntervalSince1970: 0)
        table.merge([
            conn("old", start: base),
            conn("new", start: base.addingTimeInterval(60)),
            conn("mid", start: base.addingTimeInterval(30)),
        ])
        #expect(table.rows.map(\.id) == ["new", "mid", "old"])
    }

    @Test func removeDropsASingleRow() {
        var table = ConnectionTable()
        table.merge([conn("a"), conn("b")])
        table.remove("a")
        #expect(table.rows.map(\.id) == ["b"])
    }

    // Close All drops the live connections and leaves the ones that already
    // finished, matching the list the user is looking at.
    @Test func removeActiveDropsOnlyLiveRows() {
        var table = ConnectionTable()
        table.merge([conn("finished"), conn("live")])
        table.merge([conn("live")])
        table.removeActive()
        #expect(table.rows.map(\.id) == ["finished"])
        #expect(table.activeIDs.isEmpty)
    }
}

struct ConnectionFilterTests {
    @Test func activeOnlyHidesFinishedRows() {
        var table = ConnectionTable()
        table.merge([conn("finished", host: "finished.example"), conn("live", host: "live.example")])
        table.merge([conn("live", host: "live.example")])
        let filtered = ConnectionTable.filtered(table.rows,
                                                activeOnly: true,
                                                activeIDs: table.activeIDs,
                                                searchText: "")
        #expect(filtered.map(\.id) == ["live"])
    }

    @Test func searchMatchesHostChainRuleAndProcess() {
        let rows = [
            conn("host", host: "example.com"),
            conn("chain", chains: ["PROXY", "EDGE"]),
            conn("rule", rule: "DOMAIN-SUFFIX"),
            conn("process", processName: "curl"),
            conn("none", host: "other.test", rule: "MATCH"),
        ]
        func ids(_ query: String) -> [String] {
            ConnectionTable.filtered(rows, activeOnly: false, activeIDs: [], searchText: query).map(\.id)
        }
        #expect(ids("EXAMPLE") == ["host"])
        #expect(ids("edge") == ["chain"])
        #expect(ids("domain-suffix") == ["rule"])
        #expect(ids("CURL") == ["process"])
        #expect(ids("") == ["host", "chain", "rule", "process", "none"])
        #expect(ids("no-such-thing").isEmpty)
    }

    @Test func activeOnlyAndSearchCombine() {
        var table = ConnectionTable()
        table.merge([conn("live", host: "match.example"), conn("finished", host: "match.example")])
        table.merge([conn("live", host: "match.example")])
        let filtered = ConnectionTable.filtered(table.rows,
                                                activeOnly: true,
                                                activeIDs: table.activeIDs,
                                                searchText: "match")
        #expect(filtered.map(\.id) == ["live"])
    }
}
