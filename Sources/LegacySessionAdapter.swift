import Foundation

/// Temporary S2 bridge. SessionModel remains the only owner of legacy async IO.
/// S3 must remove this file after migrating the underlying responsibilities.
@MainActor final class LegacySessionAdapter: LegacySessionPort {
    let model: SessionModel
    init(model: SessionModel) { self.model = model }
    var configuration: ConfigSnapshot {
        ConfigSnapshot(serverURL: model.serverURL, deviceID: model.deviceID,
                       userID: model.userID, revision: AppStorage.configurationRevision,
                       hasCredential: !model.deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var configurationLocked: Bool { model.configurationLocked }
    var isRecording: Bool { model.isRecording }
    var wantsCapture: Bool { model.intent == .wanted }
    var terminating: Bool { model.terminating }
    var meeting: MeetingContext { model.meetingContext }
    var board: StatusBoard { model.board }
    var presentation: SessionPresentation { model.presentation }
    func updateConfiguration(_ field: ConfigurationField, value: String) {
        switch field {
        case .serverURL: model.serverURL = value
        case .deviceID: model.deviceID = value
        case .userID: model.userID = value
        case .credential: model.deviceToken = value
        }
    }
    func resetConfiguration() { model.resetToDefaults() }
    func startCapture() { model.legacyStartCapture() }
    func stopCapture() { model.legacyStopCapture() }
    func endMeeting() { model.terminateMeeting() }
    func checkConnection() async { await model.refreshNet() }
}
