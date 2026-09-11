import Foundation
import Testing
@testable import WaypointCore

struct SpeedSampleSeriesTests {
    @Test func storesValuesDateAndFirstId() {
        var series = SpeedSampleSeries(limit: 120)
        let date = Date(timeIntervalSince1970: 1_000)
        series.append(up: 11, down: 22, at: date)
        #expect(series.samples == [SpeedSample(id: 1, date: date, up: 11, down: 22)])
    }

    @Test func idsKeepCountingUpAcrossTheWindow() {
        var series = SpeedSampleSeries(limit: 2)
        let base = Date(timeIntervalSince1970: 0)
        series.append(up: 1, down: 11, at: base)
        series.append(up: 2, down: 22, at: base.addingTimeInterval(1))
        series.append(up: 3, down: 33, at: base.addingTimeInterval(2))
        #expect(series.samples.map(\.id) == [2, 3])
        #expect(series.samples.map(\.up) == [2, 3])
        #expect(series.samples.map(\.down) == [22, 33])
    }

    @Test func growsUntilTheLimitThenSlides() {
        var series = SpeedSampleSeries(limit: 3)
        for value in 1...5 {
            series.append(up: value, down: value * 10, at: Date(timeIntervalSince1970: Double(value)))
        }
        #expect(series.samples.map(\.id) == [3, 4, 5])
        #expect(series.samples.map(\.up) == [3, 4, 5])
    }
}

struct CommaSeparatedListTests {
    @Test func splitsTrimsAndDropsEmptyEntries() {
        #expect(CommaSeparatedList.parse("a.com, b.com ,c.com") == ["a.com", "b.com", "c.com"])
        #expect(CommaSeparatedList.parse("a.com,") == ["a.com"])
        #expect(CommaSeparatedList.parse(" , , ") == [])
        #expect(CommaSeparatedList.parse("") == [])
    }

    @Test func keepsInnerSpacesAndDuplicates() {
        #expect(CommaSeparatedList.parse("192.168.0.0/16, 192.168.0.0/16") == ["192.168.0.0/16", "192.168.0.0/16"])
        #expect(CommaSeparatedList.parse("my ssid") == ["my ssid"])
    }
}
