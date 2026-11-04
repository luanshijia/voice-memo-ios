import XCTest
@testable import VoiceMemo

final class CrashEvidenceTests: XCTestCase {
    func testNormalRelaunchKeepsCrashAndMatchingSteps() {
        let saved = ["crash": "SIGSEGV", "steps": "disconnect started"]
        XCTAssertEqual(CrashLog.retainedEvidence(crash: nil, steps: "new normal run",
                                                failure: nil, saved: saved), saved)
    }

    func testNewCrashReplacesOldEvidenceWithoutMixingSteps() {
        let saved = ["crash": "old signal", "steps": "old steps", "failure": "old exception"]
        XCTAssertEqual(CrashLog.retainedEvidence(crash: "SIGSEGV", steps: "new stop",
                                                failure: nil, saved: saved),
                       ["crash": "SIGSEGV", "steps": "new stop"])
    }

    func testStickyExceptionDoesNotOverwriteItsOriginalSteps() {
        let saved = ["failure": "same exception", "steps": "original stop"]
        XCTAssertEqual(CrashLog.retainedEvidence(crash: nil, steps: "later run",
                                                failure: "same exception", saved: saved), saved)
    }
}
