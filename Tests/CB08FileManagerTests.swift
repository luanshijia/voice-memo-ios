import XCTest
@testable import VoiceMemo

@MainActor final class CB08FileManagerTests: XCTestCase {
    final class Device: CB08FileDevice {
        var connected = true
        var connectionID: UUID? = UUID()
        var recordState: CB08RecordingState? = .stopped
        var onPacket: ((Data) -> Void)?
        var onLoss: (() -> Void)?
        var onFileEvent: ((CB08SDKEvent) -> Void)?
        var list: [[String: Any]] = [["name": "note20261107-120000.opus", "size": "200", "time": "10"]]
        var listRequests = 0
        var deletions: [String] = []
        var sendList = true
        var deleteState = "0"
        var actuallyDelete = true
        var onQuery: (() -> Void)?
        var onList: (() -> Void)?
        func refreshRecordState(timeout: Duration) async -> CB08RecordingState? { onQuery?(); return recordState }
        func command(_ action: CB08RecordAction) {}
        func waitForRecordAction(timeout: Duration) async -> Bool { false }
        func discardQueuedPackets() {}
        func event(_ object: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: object)
            onFileEvent?(CB08SDKEvent.parse(String(decoding: data, as: UTF8.self))!)
        }
        func requestFiles() {
            listRequests += 1
            if let onList { onList(); return }
            if sendList { event(["cmd": 4, "state": 0, "finish": 1, "data": list]) }
        }
        func deleteFile(named name: String) {
            deletions.append(name)
            if actuallyDelete && deleteState == "0" { list.removeAll { $0["name"] as? String == name } }
            event(["cmd": "14", "state": "0", "data": ["delete_state": deleteState]])
        }
    }
    func manager(_ device: Device, timeout: Duration = .seconds(1)) -> CB08FileManager {
        let manager = CB08FileManager(device: device, operations: CB08DeviceManager(device: device), timeout: timeout)
        manager.operationAllowed = { true }
        return manager
    }
    func testListParserPreservesArrayFinishAndUnits() throws {
        let event = try XCTUnwrap(CB08SDKEvent.parse(#"{"cmd":"4","state":"0","finish":"1","data":[{"name":"note20261107-120000.opus","size":"6400","time":"4"}]}"#))
        let file = try CB08CardFile(XCTUnwrap(event.fileEntries?.first))
        XCTAssertEqual(event.finish, 1); XCTAssertEqual(file.bytes, 6400); XCTAssertEqual(file.seconds, 4)
        XCTAssertNotNil(file.recordedAt)
    }
    func testPartialBatchesAccumulateAndFinalBatchIsIncluded() async throws {
        let d = Device(); let m = manager(d)
        d.onList = {
            d.event(["cmd": 4, "state": 0, "finish": 0, "data": d.list])
            d.event(["cmd": 4, "state": 0, "finish": 1,
                     "data": [["name": "note20261107-130000.opus", "size": 30, "time": 2]]])
        }
        await m.refresh()?.value
        XCTAssertEqual(m.files.count, 2)
        XCTAssertEqual(m.sortedFiles(newestFirst: true).first?.name, "note20261107-130000.opus")
        XCTAssertEqual(m.sortedFiles(newestFirst: false).first?.name, "note20261107-120000.opus")
    }
    func testDeleteRequiresAckAndAbsenceFromRefreshedList() async throws {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        let file = try XCTUnwrap(m.visibleFiles.first)
        await m.delete(file)?.value
        XCTAssertEqual(d.deletions, [file.name]); XCTAssertTrue(m.visibleFiles.isEmpty)
        XCTAssertTrue(m.status.contains("删除已确认")); XCTAssertEqual(d.listRequests, 3)
    }
    func testSuccessAckWithFileStillPresentIsNotSuccess() async throws {
        let d = Device(); d.actuallyDelete = false; let m = manager(d)
        await m.refresh()?.value
        await m.delete(try XCTUnwrap(m.files.first))?.value
        XCTAssertEqual(m.files.count, 1); XCTAssertTrue(m.status.contains("删除未确认"))
    }
    func testDeleteFailureLeavesFileAndReportsFailure() async throws {
        let d = Device(); d.deleteState = "1"; let m = manager(d)
        await m.refresh()?.value
        await m.delete(try XCTUnwrap(m.files.first))?.value
        XCTAssertEqual(m.files.count, 1); XCTAssertFalse(m.status.contains("删除已确认"))
    }
    func testRecordingAndPauseNeverSendDelete() async throws {
        for state in [CB08RecordingState.recording, .paused, .inactive] {
            let d = Device(); let m = manager(d)
            await m.refresh()?.value
            let file = try XCTUnwrap(m.files.first)
            d.recordState = state
            XCTAssertNil(m.delete(file)); XCTAssertTrue(d.deletions.isEmpty)
        }
    }
    func testStateChangesDuringPreflightPreventDelete() async throws {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        d.onQuery = { d.recordState = .recording }
        await m.delete(try XCTUnwrap(m.files.first))?.value
        XCTAssertTrue(d.deletions.isEmpty)
    }
    func testConnectionChangesInvalidateDisplayedFilesAndDelete() async throws {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        let file = try XCTUnwrap(m.files.first)
        d.connectionID = UUID()
        XCTAssertFalse(m.hasCurrentList); XCTAssertTrue(m.visibleFiles.isEmpty)
        XCTAssertNil(m.delete(file)); XCTAssertTrue(d.deletions.isEmpty)
    }
    func testChangedMetadataRequiresNewSelection() async throws {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        let file = try XCTUnwrap(m.files.first)
        d.list[0]["size"] = "999"
        await m.delete(file)?.value
        XCTAssertTrue(d.deletions.isEmpty); XCTAssertTrue(m.status.contains("已变化"))
    }
    func testOldConfirmationCannotDeleteAfterReconnectAndRefresh() async throws {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        let file = try XCTUnwrap(m.files.first), oldConnection = d.connectionID
        d.connectionID = UUID()
        await m.refresh()?.value
        XCTAssertNil(m.delete(file, expectedConnection: oldConnection))
        XCTAssertTrue(d.deletions.isEmpty)
    }
    func testTimeoutBlocksLateRepliesAndFurtherCommandsUntilReconnect() async {
        let d = Device(); d.sendList = false; let m = manager(d, timeout: .milliseconds(25))
        await m.refresh()?.value
        d.event(["cmd": 4, "state": 0, "finish": 1, "data": d.list])
        XCTAssertFalse(m.canRefresh); XCTAssertFalse(m.hasCurrentList); XCTAssertNil(m.refresh())
        XCTAssertTrue(m.requiresReconnect)
        d.connectionID = UUID(); d.sendList = true
        await m.refresh()?.value
        XCTAssertEqual(m.visibleFiles.count, 1); XCTAssertTrue(m.canRefresh)
        XCTAssertFalse(m.requiresReconnect)
    }
    func testMalformedListDoesNotReplaceCompletedSnapshot() async {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        d.onList = { d.event(["cmd": 4, "state": 0, "finish": 1, "data": ["not": "an array"]]) }
        await m.refresh()?.value
        XCTAssertEqual(m.files.count, 1); XCTAssertFalse(m.canRefresh)
    }
    func testMissingStatusCannotBeRetriedAsAnExplicitDeviceFailure() async {
        let d = Device(); let m = manager(d)
        d.onList = { d.event(["cmd": 4, "finish": 1, "data": d.list]) }
        await m.refresh()?.value
        XCTAssertTrue(m.requiresReconnect); XCTAssertFalse(m.hasCurrentList)
        XCTAssertNil(m.refresh())
    }
    func testFileOperationsHoldExistingDeviceLockAndRejectOverlap() async {
        let d = Device(); let operations = CB08DeviceManager(device: d)
        let m = CB08FileManager(device: d, operations: operations)
        m.operationAllowed = { true }
        let task = m.refresh()
        XCTAssertTrue(operations.busy); XCTAssertNil(m.refresh())
        XCTAssertNil(operations.stopIndependent { true })
        await task?.value
        XCTAssertFalse(operations.busy); XCTAssertFalse(m.busy)
    }
    func testUnknownDatesAndUnsafeNamesAreNotInventedOrDeleted() throws {
        let file = try CB08CardFile(["name": "custom.opus", "size": "unknown"])
        XCTAssertNil(file.recordedAt); XCTAssertNil(file.bytes); XCTAssertNil(file.seconds)
        XCTAssertFalse(CB08CardFile.supportsDeletion("../wrong.opus"))
        XCTAssertFalse(CB08CardFile.supportsDeletion("wrong\n.opus"))
        XCTAssertFalse(CB08CardFile.supportsDeletion("folder\\wrong.opus"))
    }
    func testSDKFormattedLongNameIsPassedUnchangedToDelete() async throws {
        let d = Device()
        let name = "note 2026-11-07_12-00-00.opus"
        d.list = [["name": name, "size": "200", "time": "10"]]
        let m = manager(d)
        await m.refresh()?.value
        let file = try XCTUnwrap(m.files.first)
        XCTAssertGreaterThan(name.utf8.count, 24)
        XCTAssertTrue(CB08CardFile.supportsDeletion(name))
        XCTAssertNotNil(file.recordedAt)
        await m.delete(file)?.value
        XCTAssertEqual(d.deletions, [name])
        XCTAssertTrue(m.visibleFiles.isEmpty)
        XCTAssertTrue(m.status.contains("删除已确认"))
    }
    func testBothSDKDateFormatsSortByActualDateAndRejectInvalidDates() throws {
        let old = try CB08CardFile(["name": "note20261107-120000.opus"])
        let spaced = try CB08CardFile(["name": "note 2026-11-07_12-00-00.opus"])
        let call = try CB08CardFile(["name": "call 2026-11-07_13-00-00.opus"])
        XCTAssertEqual(try XCTUnwrap(old.recordedAt), try XCTUnwrap(spaced.recordedAt))
        XCTAssertGreaterThan(try XCTUnwrap(call.recordedAt), try XCTUnwrap(spaced.recordedAt))
        XCTAssertNil(try CB08CardFile(["name": "note 2026-02-30_12-00-00.opus"]).recordedAt)
        XCTAssertNil(try CB08CardFile(["name": "note 2026-11-07_25-00-00.opus"]).recordedAt)
    }
    func testUnconfirmedStopExplainsDisabledDeleteAndNeverSendsCommand() async throws {
        let d = Device(); let m = manager(d)
        await m.refresh()?.value
        let file = try XCTUnwrap(m.files.first)
        d.recordState = .inactive
        XCTAssertFalse(m.canDelete)
        XCTAssertEqual(m.deleteBlockedReason, "停止尚未确认，请先停止并保存")
        XCTAssertNil(m.delete(file)); XCTAssertTrue(d.deletions.isEmpty)
        d.recordState = .stopped
        XCTAssertTrue(m.canDelete); XCTAssertNil(m.deleteBlockedReason)
        m.operationAllowed = { false }
        m.operationBlockReason = { "会议尚未结束，暂不可删除" }
        XCTAssertFalse(m.canDelete)
        XCTAssertEqual(m.deleteBlockedReason, "会议尚未结束，暂不可删除")
    }
    func testMixedFilenameFormatsSortChronologically() async throws {
        let d = Device()
        d.list = [
            ["name": "note20261106-120000.opus"],
            ["name": "call 2026-11-08_12-00-00.opus"],
            ["name": "note 2026-11-07_12-00-00.opus"]
        ]
        let m = manager(d)
        await m.refresh()?.value
        XCTAssertEqual(m.sortedFiles(newestFirst: true).map(\.name), [
            "call 2026-11-08_12-00-00.opus", "note 2026-11-07_12-00-00.opus", "note20261106-120000.opus"
        ])
    }
}
