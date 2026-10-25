import XCTest
@testable import VoiceMemo

final class ControlResponseTests: XCTestCase {
    func testSharedPythonSwiftFixtureMatrix() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ControlResponseFixtures", withExtension: "json"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for item in cases {
            let kind = try XCTUnwrap(item["kind"] as? String)
            let body = try XCTUnwrap(item["body"])
            let valid = try XCTUnwrap(item["valid"] as? Bool)
            XCTAssertEqual(SessionControlContract.responseProblem(kind, object: body) == nil, valid,
                           item["name"] as? String ?? "unnamed")
        }
    }
}
