import Combine
import Foundation
import LiveKit

/// Owns transport instances, async generations and disconnection serialization.
@MainActor final class ConnectionWorker: ObservableObject {
    private let room: VoiceRoom
    @Published private(set) var generation = 0
    @Published private(set) var live: Room?
    @Published private(set) var connecting: Task<Void, Never>?
    private(set) var pendingDisconnect: Task<Void, Never>?
    @Published private(set) var endReason: LinkReason?
    @Published private(set) var probe = Status<LinkDesired, LinkObserved, LinkReason>(
        desired: .wanted, observed: .notStarted)
    private let settings: SettingsWorker
    private let probeHost: (String, UInt16) async -> Bool
    var onNote: ((String) -> Void)?
    var onProtocolIssue: ((String) -> Void)?
    var onEnded: ((String) -> Void)?
    var onTranscript: ((String, String, Double, String, Double?, Double, [String: Any]) -> Void)?
    var controlObservation: () -> MeetingContext = { .empty }
    var recognitionProgress: () -> Double = { 0 }

    init(settings: SettingsWorker, room: VoiceRoom? = nil,
         probeHost: @escaping (String, UInt16) async -> Bool = { await NetProbe.check(host: $0, port: $1) }) {
        self.settings = settings
        self.room = room ?? VoiceRoom()
        self.probeHost = probeHost
        self.room.onState = { [weak self] _ in self?.objectWillChange.send() }
        self.room.onEndReason = { [weak self] reason in self?.endReason = reason }
        self.room.onNote = { [weak self] note in self?.onNote?(note) }
        self.room.onProtocolIssue = { [weak self] issue in self?.onProtocolIssue?(issue) }
        self.room.onEnded = { [weak self] reason in self?.onEnded?(reason) }
        self.room.onTranscript = { [weak self] type, who, seconds, text, gap, ts, raw in
            self?.onTranscript?(type, who, seconds, text, gap, ts, raw)
        }
    }
    func connect(url: String, token: String, identity: String) async throws -> Room {
        try await room.connect(url: url, token: token, identity: identity)
    }
    func disconnect(_ target: Room) async { await room.disconnect(target) }
    func send(_ payload: [String: Any]) async { await room.send(payload) }
    @discardableResult func invalidate() -> Int { generation += 1; return generation }
    /// Capture the previous wait synchronously before scheduling a new attempt.
    /// A stop in the same event-loop turn must never become its own predecessor.
    func beginConnection(_ attempt: @escaping () async -> Void) {
        let previous = pendingDisconnect
        pendingDisconnect = nil
        connecting = Task {
            await previous?.value
            await attempt()
        }
    }
    func resetEndReason() { endReason = nil }
    func connected(_ target: Room) { live = target }
    func interrupted() { live = nil }
    func enqueueDisconnect(beforeDisconnect: @escaping () async -> Void,
                           completion: @escaping () async -> Void) {
        let previous = pendingDisconnect
        let inflight = connecting
        let target = live
        connecting = nil
        live = nil
        pendingDisconnect = Task {
            await previous?.value
            await inflight?.value
            await beforeDisconnect()
            if let target { await self.room.disconnect(target) }
            await completion()
        }
    }
    var network: LinkObserved {
        Date().timeIntervalSince(probe.lastSeen) <= StatusBoard.probeStaleAfter ? probe.observed : .unknown
    }
    var media: LinkObserved { status(desired: .wanted).observed }
    var controlIsFresh: Bool { controlObservation().isFresh() }
    var recognitionSeconds: Double { recognitionProgress() }
    var desktopAudioEvidence: String { "尚无按分段统计的实际样本证据" }
    func status(desired: LinkDesired) -> Status<LinkDesired, LinkObserved, LinkReason> {
        let observed: LinkObserved
        switch room.connectionState {
        case .connected?: observed = .connected
        case .connecting?: observed = .connecting
        case .reconnecting?: observed = .reconnecting
        case .disconnected?: observed = .disconnected
        case nil: observed = desired == .wanted && connecting != nil ? .connecting : .notStarted
        default: observed = .unknown
        }
        return Status(desired: desired, observed: observed,
                      reason: observed == .disconnected ? (endReason ?? .disconnected) : nil,
                      lastSeen: Date(), generation: generation)
    }
    func preflightControl() async {
        let revision = settings.snapshot.revision
        let config = settings.config
        let requestGeneration = generation
        let ok: Bool
        if let hp = NetProbe.hostPort(from: config.url) { ok = await probeHost(hp.host, hp.port) }
        else { ok = false }
        guard revision == settings.snapshot.revision, requestGeneration == generation else { return }
        probe = Status(desired: .wanted, observed: ok ? .connected : .disconnected,
                       reason: ok ? nil : .probeTimeout, lastSeen: Date(), generation: generation)
    }
}
