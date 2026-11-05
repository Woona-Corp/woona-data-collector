import XCTest
@testable import Woona

final class SessionChartTests: XCTestCase {
    private let stream = ChartStreamKey(sensorType: 2, channel: 1)

    func testHistoryRetentionAndPanZoomRemainBounded() {
        var chart = SessionChart()
        chart.appendChartSamples([stream: (0..<2_000).map {
            ChartPoint(timeMillis: UInt64($0) * 1_000, value: Float($0), startsNewSegment: false)
        }])
        XCTAssertEqual(chart.chart.sessionStartMillis, 1_099_000)
        XCTAssertEqual(chart.chart.latestPointMillis, 1_999_000)
        chart.panChartLeft()
        XCTAssertFalse(chart.chart.isFollowingLive)
        XCTAssertTrue(chart.chart.canPanRight)
        chart.zoomChartIn()
        XCTAssertLessThan(chart.chart.yAxisAbsRange, 32_768)
        chart.resetChartY()
        XCTAssertEqual(chart.chart.yAxisAbsRange, 32_768)
        chart.jumpToLive()
        XCTAssertTrue(chart.chart.isFollowingLive)
    }

    func testDownsamplingKeepsSegmentBreaksAndRenderingLimit() {
        var chart = SessionChart()
        chart.appendChartSamples([stream: (0..<8_000).map {
            ChartPoint(timeMillis: UInt64($0) * 10, value: Float($0), startsNewSegment: $0 == 6_500)
        }])
        XCTAssertLessThanOrEqual(chart.chart.points.count, 1_200)
        XCTAssertTrue(chart.chart.points.contains { $0.startsNewSegment })
        XCTAssertEqual(chart.chart.points.last?.timeMillis, 79_990)
    }

    func testIndependentChartsAndClearPreserveSelection() {
        var first = SessionChart()
        first.appendChartSamples([stream: [ChartPoint(timeMillis: 100, value: 12, startsNewSegment: false)]])
        var second = first
        second.clearChartHistory()
        second.selectSensorType(4)
        second.selectChannel(2)
        second.clearChartHistory()
        XCTAssertEqual(first.chart.points.count, 1)
        XCTAssertTrue(second.chart.points.isEmpty)
        XCTAssertEqual(second.selectedSensorType, 4)
        XCTAssertEqual(second.selectedChannel, 2)
    }
}
