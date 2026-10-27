import Combine
import Foundation
import LiveKit

/// CB08 owns capture; this provider only publishes authorized PCM in the current segment.
@MainActor final class CB08InputProvider: ObservableObject {
    @Published private(set) var decodedPackets = 0
    @Published private(set) var decodeFailures = 0
    @Published private(set) var submittedSamples = 0
    @Published private(set) var failure: String?
    @Published private(set) var flowing = false
    private let device: CB08DeviceControlling
    private let publisher: PCMAudioPublishing
    private let makeDecoder: () throws -> OpusDecoding
    private var decoder: OpusDecoding?
    private var room: Room?
    private var context: ExecutionContext?
    private var accepting = false
    private var epoch = 0
    private var paused = false
    private var recordingOwner: (meetingID: String, connectionID: UUID)?
    private var ownsRecording: Bool {
        guard let owner = recordingOwner else { return false }
        return device.connected && owner.connectionID == device.connectionID
    }
    private var pendingHalt: CB08RecordAction?
    var onFault: (() -> Void)?
    var onFlow: (() -> Void)?
    var isAvailable: Bool { device.connected }

    init(device: CB08DeviceControlling, publisher: PCMAudioPublishing,
         makeDecoder: @escaping () throws -> OpusDecoding = { try OpusDecoder() }) {
        self.device = device; self.publisher = publisher; self.makeDecoder = makeDecoder
        device.onPacket = { [weak self] data in self?.receive(data) }
        device.onLoss = { [weak self] in self?.fault("外设连接或回调中断") }
    }
    func bind(_ room: Room?) { self.room = room }
    func start(context: ExecutionContext) async throws {
        guard device.connected, let connectionID = device.connectionID, let room else { throw CB08InputError.unavailable }
        guard context.channel == "external_audio", let meetingID = context.meetingID,
              context.segmentID != nil, context.generation != nil else { throw CB08InputError.invalidContext }
        epoch += 1; let attempt = epoch
        let recordState = await device.refreshRecordState(timeout: .seconds(3))
        guard attempt == epoch, device.connected, device.connectionID == connectionID else {
            throw CB08InputError.unavailable
        }
        guard let recordState else { throw CB08InputError.recordStateUnknown }
        // Do not adopt a card's unrelated existing recording into a new meeting.
        let canResume = paused && ownsRecording && recordingOwner?.meetingID == meetingID
        guard recordState == 0 || (recordState == 2 && canResume) else {
            if recordState == 2 { throw CB08InputError.pausedRecordingNotOwned }
            throw CB08InputError.alreadyRecording(recordState)
        }
        let decoder = try makeDecoder()
        try await publisher.startPCM(in: room)
        guard attempt == epoch, device.connected, device.connectionID == connectionID else {
            await publisher.stopPCM(in: room); throw CB08InputError.unavailable
        }
        guard device.recordState == recordState else {
            await publisher.stopPCM(in: room); throw CB08InputError.recordStateChanged
        }
        self.decoder = decoder; self.context = context
        decodedPackets = 0; decodeFailures = 0; submittedSamples = 0
        device.discardQueuedPackets()
        failure = nil; flowing = false; accepting = true
        let resume = recordState == 2 && canResume
        paused = false
        recordingOwner = (meetingID, connectionID); pendingHalt = nil
        device.command(resume ? .resume : .start)
    }
    /// Close the gate synchronously, before any asynchronous track disconnect.
    func closeGate() { accepting = false; flowing = false; epoch += 1; device.discardQueuedPackets() }
    func requestHalt(_ action: CB08RecordAction) {
        closeGate()
        guard ownsRecording else { recordingOwner = nil; paused = false; return }
        paused = action == .pause
        if pendingHalt != action {
            device.command(action); pendingHalt = action
        }
        if action == .stop { recordingOwner = nil }
    }
    func pause() async {
        requestHalt(.pause)
        if let room { await publisher.stopPCM(in: room) }
        room = nil; decoder = nil; context = nil
    }
    func stop() async {
        requestHalt(.stop)
        if let room { await publisher.stopPCM(in: room) }
        room = nil; decoder = nil; context = nil
    }
    func interrupted() { closeGate() }
    private func fault(_ reason: String) {
        let active = accepting
        closeGate(); failure = reason
        if active { onFault?() }
    }
    private func receive(_ data: Data) {
        guard accepting, context != nil, let decoder else { return }
        do {
            let result = try decoder.decode(packet: data)
            guard accepting else { return }
            try publisher.submitPCM(result.pcm)
            decodedPackets += 1; submittedSamples += result.metrics.decodedSamples
            if !flowing { flowing = true; onFlow?() }
        } catch {
            decodeFailures += 1; fault("音频解码或提交失败，已请求暂停")
        }
    }
}
enum CB08InputError: LocalizedError {
    case unavailable, invalidContext, recordStateUnknown, recordStateChanged, pausedRecordingNotOwned
    case alreadyRecording(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "CB08 未连接或连接已变化"
        case .invalidContext: return "CB08 采集上下文无效"
        case .recordStateUnknown: return "未收到 CB08 录音状态，请刷新设备状态后重试"
        case .recordStateChanged: return "CB08 录音状态在启动期间发生变化，请刷新设备状态后重试"
        case .pausedRecordingNotOwned: return "CB08 存在不属于当前会议的暂停录音，请先在设备端处理"
        case .alreadyRecording(let state): return "CB08 当前录音状态为 \(state)，请先停止设备录音后重试"
        }
    }
}
