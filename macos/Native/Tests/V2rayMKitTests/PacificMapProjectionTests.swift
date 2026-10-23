import XCTest
@testable import V2rayMKit

final class PacificMapProjectionTests: XCTestCase {
    private let shanghai = GlobePlace(city: "上海", latitude: 31.2304, longitude: 121.4737)
    private let la = GlobePlace(city: "洛杉矶", latitude: 34.0522, longitude: -118.2437)
    func testPacificCrossingAndProjectionRoundTrip() {
        let map = PacificMapProjection(size: CGSize(width: 568, height: 560))
        let a = map.point(shanghai), b = map.point(la)
        XCTAssertLessThan(a.x, b.x)
        XCTAssertLessThan(b.x - a.x, map.plot.width * 0.7)
        for place in [shanghai, la] {
            XCTAssertTrue(map.plot.contains(map.point(place)))
            let value = map.coordinate(map.point(place))
            XCTAssertEqual(value.latitude, place.latitude, accuracy: 0.0001)
            XCTAssertEqual(value.longitude, PacificMapProjection.longitude(place.longitude), accuracy: 0.0001)
        }
    }
    func testViewportIsFixedAndOutsideLocationsAreExplicit() {
        let size = CGSize(width: 568, height: 560)
        let map = PacificMapProjection(size: size)
        let before = map.point(shanghai)
        let london = GlobePlace(city: "伦敦", latitude: 51.5, longitude: -0.1)
        XCTAssertTrue(map.isOutside(london))
        XCTAssertFalse(map.isOutside(shanghai))
        XCTAssertFalse(map.isOutside(la))
        XCTAssertEqual(map.point(shanghai), map.displayPoint(shanghai))
        _ = map.curve(from: shanghai, to: london)
        XCTAssertEqual(map.world, PacificMapProjection(size: size).world)
        XCTAssertEqual(before, map.point(shanghai))
    }
    func testOffscreenPointsAndCompleteParticlePathsStayInsideFixedViewport() {
        let places = [shanghai, la, GlobePlace(city: "", latitude: 85, longitude: -0.1),
                      GlobePlace(city: "", latitude: -85, longitude: 0.1), GlobePlace(city: "", latitude: 0, longitude: 180)]
        for size in [CGSize(width: 568, height: 560), CGSize(width: 400, height: 600), CGSize(width: 900, height: 400)] {
            let map = PacificMapProjection(size: size)
            for a in places {
                XCTAssertTrue(map.canvas.insetBy(dx: 8, dy: 8).contains(map.displayPoint(a)))
                for b in places {
                    for reversed in [false, true] {
                        let curve = map.curve(from: a, to: b, returnPath: reversed)
                        for step in 0...100 {
                            XCTAssertTrue(map.canvas.insetBy(dx: 8, dy: 8).contains(curve.point(at: Double(step) / 100)))
                        }
                    }
                }
            }
        }
    }
}
