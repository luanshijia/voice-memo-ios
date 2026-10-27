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
        // Do not adopt a card's unrelated existing recording into a new meeting.
        let canResume = paused && ownsRecording && recordingOwner?.meetingID == meetingID
        guard device.recordState == 0 || (device.recordState == 2 && canResume) else {
            throw CB08InputError.alreadyRecording
        }
        let decoder = try makeDecoder()
        epoch += 1; let attempt = epoch
        try await publisher.startPCM(in: room)
        guard attempt == epoch, device.connected, device.connectionID == connectionID else {
            await publisher.stopPCM(in: room); throw CB08InputError.unavailable
        }
        self.decoder = decoder; self.context = context
        decodedPackets = 0; decodeFailures = 0; submittedSamples = 0
        device.discardQueuedPackets()
        failure = nil; flowing = false; accepting = true
        let resume = device.recordState == 2 && canResume
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
enum CB08InputError: Error { case unavailable, invalidContext, alreadyRecording }
