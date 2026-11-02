import AVFoundation
import UIKit
import XCTest
@testable import VoiceMemo

@MainActor final class PresentationRefinementTests: XCTestCase {
    func testTemporaryTranscriptDropsEarlierExplicitLinesOnly() {
        let original = "第一行\n第二行\n第三行"
        XCTAssertEqual(PartialTranscriptTail.latest(original, width: 300), "第二行\n第三行")
        XCTAssertEqual(original, "第一行\n第二行\n第三行")
        XCTAssertEqual(PartialTranscriptTail.latest("一句短话", width: 300), "一句短话")
        XCTAssertEqual(PartialTranscriptTail.latest("", width: 300), "")
        XCTAssertEqual(PartialTranscriptTail.latest(original, width: 0), "")
    }

    func testLatestTwoLinesFollowActualWidthAndKeepTheEnd() {
        let original = String(repeating: "会议字幕 test words，最新内容。", count: 10)
        let narrow = PartialTranscriptTail.latest(original, width: 120)
        let wide = PartialTranscriptTail.latest(original, width: 320)
        XCTAssertTrue(original.hasSuffix(narrow))
        XCTAssertTrue(original.hasSuffix(wide))
        XCTAssertLessThan(narrow.count, wide.count)
        XCTAssertLessThan(wide.count, original.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = PartialTranscriptTail.lineSpacing
        let size = (narrow as NSString).boundingRect(with: CGSize(width: 120, height: 1000),
            options: [.usesLineFragmentOrigin], attributes: [.font: PartialTranscriptTail.font,
            .paragraphStyle: paragraph], context: nil)
        XCTAssertLessThanOrEqual(size.height, PartialTranscriptTail.panelHeight)
    }

    func testEmojiAndCombiningCharactersRemainValidAtClippedBoundary() {
        let original = String(repeating: "家庭👩‍👩‍👦 e\u{301} 最新内容。", count: 15)
        let tail = PartialTranscriptTail.latest(original, width: 140)
        XCTAssertTrue(original.hasSuffix(tail))
        XCTAssertTrue(tail.hasSuffix("最新内容。"))
        XCTAssertFalse(tail.unicodeScalars.contains { $0.value == 0xFFFD })
        XCTAssertNotEqual(tail.unicodeScalars.first?.value, 0x200D)
    }

    func testKnownPublicMicrophoneModesHaveAccurateNames() {
        XCTAssertEqual(InputWorker.microphoneModeText(rawValue: AVCaptureDevice.MicrophoneMode.standard.rawValue), "标准")
        XCTAssertEqual(InputWorker.microphoneModeText(rawValue: AVCaptureDevice.MicrophoneMode.voiceIsolation.rawValue), "语音突显")
        XCTAssertEqual(InputWorker.microphoneModeText(rawValue: AVCaptureDevice.MicrophoneMode.wideSpectrum.rawValue), "宽谱")
    }

    func testUnknownMicrophoneModeIsNeverInventedAsAutomatic() {
        XCTAssertEqual(InputWorker.microphoneModeText(rawValue: 999), "未知")
    }
}
