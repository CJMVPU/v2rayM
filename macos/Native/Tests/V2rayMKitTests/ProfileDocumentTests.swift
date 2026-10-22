import XCTest
@testable import V2rayMKit
final class ProfileDocumentTests: XCTestCase {
    func testEditingKeepsTransportCredentialsAndUnknownFields() throws {
        var doc = ProfileDocument(try .parse(#"{"remarks":"before","address":"test.invalid","port":443,"password":"secret","transportExtra":"{\"XhttpMode\":\"auto\",\"XhttpExtra\":\"{}\"}","futureOption":true}"#))
        doc.value["remarks"] = .string("after")
        let saved = try doc.validated()
        XCTAssertEqual(saved["password"].text, "secret")
        XCTAssertTrue(saved["futureOption"].flag)
        XCTAssertEqual(saved["transportExtra"], doc.value["transportExtra"])
    }
    func testRejectsInvalidPortAndMalformedExtra() throws {
        var doc = ProfileDocument(try .parse(#"{"remarks":"n","address":"test.invalid","port":"65536"}"#))
        XCTAssertThrowsError(try doc.validated())
        doc.value["port"] = .string("443")
        doc.value["transportExtra"] = .string("[]")
        XCTAssertThrowsError(try doc.validated())
        doc.value["transportExtra"] = .string("{}")
        XCTAssertEqual(try doc.validated()["port"], .number(443))
    }
}
