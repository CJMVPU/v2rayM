import Foundation
import XCTest
@testable import V2rayMKit

private final class FixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let status: Int
        let body: String
        if path == "/api/auth/login" {
            status = 200; body = #"{"success":true,"data":{"token":"fixture-token"}}"#
        } else if request.value(forHTTPHeaderField: "Authorization") != "Bearer fixture-token" {
            status = 401; body = #"{"success":false,"code":"unauthorized"}"#
        } else if path == "/api/failure" {
            status = 409; body = #"{"success":false,"code":"fixture_conflict"}"#
        } else if path == "/api/rejected" {
            status = 200; body = #"{"success":false,"code":"fixture_rejected"}"#
        } else if path == "/api/action" {
            status = 200; body = #"{"success":true,"data":"accepted"}"#
        } else {
            status = 200; body = #"{"success":true,"data":42}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class APIClientTests: XCTestCase {
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return APIClient(baseURL: URL(string: "http://127.0.0.1:19888")!, managementKey: "fixture", configuration: configuration)
    }
    func testConcreteAndProtocolCallsShareSuccessAndCommandResponseHandling() async throws {
        let concrete = client(), abstract: any NativeAPI = client()
        let first: Int = try await concrete.value("/api/value")
        let second: Int = try await abstract.value("/api/value")
        XCTAssertEqual(first, 42); XCTAssertEqual(second, first)
        try await concrete.perform("/api/action")
        try await abstract.perform("/api/action")
        try await concrete.send("/api/action", body: ["value": 1])
        try await abstract.send("/api/action", body: ["value": 1])
    }
    func testConcreteAndProtocolCallsRejectHTTPAndEnvelopeFailures() async throws {
        let concrete = client(), abstract: any NativeAPI = client()
        do { try await concrete.perform("/api/failure"); XCTFail("HTTP failure must throw") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "fixture_conflict") }
        do { try await abstract.perform("/api/failure"); XCTFail("HTTP failure must throw") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "fixture_conflict") }
        do { let _: Int = try await concrete.value("/api/rejected"); XCTFail("Envelope failure must throw") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "fixture_rejected") }
        do { let _: Int = try await abstract.value("/api/rejected"); XCTFail("Envelope failure must throw") }
        catch { XCTAssertEqual((error as? ClientFailure)?.code, "fixture_rejected") }
    }
}
