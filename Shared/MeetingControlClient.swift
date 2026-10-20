import Foundation
import CryptoKit

/// Shared control contract for the main App and ReplayKit extension.
/// The computer creates the meeting id and returns it with the media grant.
struct MeetingGrant: Decodable {
    let url: String
    let token: String
    let identity: String
    let ttl: Int
    let meetingID: String
    let generation: Int

    enum CodingKeys: String, CodingKey {
        case url, token, identity, ttl, generation
        case meetingID = "meeting_id"
    }
}

struct DeviceMeetingView: Decodable {
    struct PendingReport: Decodable {
        let meetingID: String
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case meetingID = "meeting_id", sha256
        }
    }
    struct Meeting: Decodable {
        struct Channel: Decodable { let status: String }
        let meetingID: String
        let status: String
        let channels: [String: Channel]
        enum CodingKeys: String, CodingKey { case meetingID = "meeting_id", status, channels }
    }
    struct Receiver: Decodable {
        let url: String
        let token: String
        let identity: String
        let meetingID: String
        enum CodingKeys: String, CodingKey { case url, token, identity; case meetingID = "meeting_id" }
    }
    let stateRevision: Int
    let meeting: Meeting?
    let view: Receiver?
    let pendingReports: [PendingReport]
    enum CodingKeys: String, CodingKey {
        case stateRevision = "state_revision", meeting, view
        case pendingReports = "pending_reports"
    }
}

enum MeetingControlClient {
    private struct PendingStart: Codable {
        let serverURL: String
        let userID: String
        let deviceID: String
        let channel: String
        let requestID: String
    }
    private struct PendingStop: Codable {
        let serverURL: String
        let meetingID: String
        let deviceID: String
        let channel: String
        let requestID: String
        let generation: Int?
    }
    private static let pendingStopKey = "vm.pendingSystemAudioStop"
    private static let pendingMicStopKey = "vm.pendingMicStop"
    private static let pendingBroadcastStartKey = "vm.pendingSystemAudioStart"
    private static let pendingMicStartKey = "vm.pendingMicStart"
    static let appGroupID = "group.com.luanshijia.voicememo"
    static let appGroupCandidates = [appGroupID, "group.com.luanshijia.voicememo.458RP2552K"]
    static let defaultServerURL = "wss://100.64.0.2:7443"
    static let defaultDeviceID = "iphone"
    static let defaultUserID = "owner"

    static func sharedDefaults() -> UserDefaults? {
        for group in appGroupCandidates where
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
            if let defaults = UserDefaults(suiteName: group) { return defaults }
        }
        return nil
    }

    static func credential() throws -> String {
        guard let token = sharedDefaults()?.string(forKey: "vm.deviceToken"),
              !token.isEmpty else {
            throw failure(10, "这台手机尚未登记设备凭据，请在设置中填写")
        }
        return token
    }

    static func requestGrant(serverURL: String, identity: String, userID: String,
                             deviceID: String, channel: String,
                             ttl: Int = 15 * 60) async throws -> MeetingGrant {
        guard var components = URLComponents(string: serverURL),
              let configuredHost = components.host else {
            throw failure(2, "连接地址不合法: \(serverURL)")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.startPath
        components.queryItems = [URLQueryItem(name: "identity", value: identity),
                                 URLQueryItem(name: "ttl", value: String(ttl))]
        guard let endpoint = components.url else {
            throw failure(2, "会议申请地址无效")
        }
        // Keep the same idempotency key across a lost HTTP response or process
        // death. It is cleared only after publication is reported or a stop is
        // durably queued; returning a grant is not proof that the caller saved it.
        let requestID = try pendingStartID(serverURL: serverURL, userID: userID,
                                           deviceID: deviceID, channel: channel)
        let payload: [String: Any] = ["request_id": requestID,
                                      "user_id": userID,
                                      "device_id": deviceID,
                                      "channel": channel]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw failure(3, "会议总管没有响应")
        }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw failure(http.statusCode, "电脑端拒绝会议申请(\(http.statusCode))\(body.isEmpty ? "" : ":" + body)")
        }
        let grant: MeetingGrant
        do {
            grant = try JSONDecoder().decode(MeetingGrant.self, from: data)
        } catch {
            throw failure(4, "会议授权回包解析失败: \(error.localizedDescription)")
        }
        guard grant.identity == identity,
              UUID(uuidString: grant.meetingID) != nil,
              !grant.token.isEmpty,
              let mediaURL = URL(string: grant.url),
              ["ws", "wss"].contains(mediaURL.scheme ?? ""),
              mediaURL.host?.caseInsensitiveCompare(configuredHost) == .orderedSame,
              grant.ttl > 0, grant.ttl <= 24 * 3600,
              grant.generation > 0 else {
            throw failure(5, "会议授权回包身份、会议号、地址或有效期无效")
        }
        return grant
    }

    static func reportObservation(serverURL: String, meetingID: String, deviceID: String,
                                  channel: String, generation: Int,
                                  observed: String) async throws {
        guard UUID(uuidString: meetingID) != nil,
              generation > 0, var components = URLComponents(string: serverURL) else {
            throw failure(14, "采集状态参数无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.observePathTemplate, meetingID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(14, "采集状态地址无效") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID, "channel": channel,
            "generation": generation, "observed": observed
        ])
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(14, "电脑端未确认采集状态")
        }
        if observed == "publishing" {
            clearPendingStart(channel: channel, deviceID: deviceID)
        }
    }

    static func sharedRegistration() throws -> (serverURL: String, deviceID: String, userID: String) {
        guard let defaults = sharedDefaults(),
              let serverURL = defaults.string(forKey: "lk.url"), !serverURL.isEmpty,
              let deviceID = defaults.string(forKey: "lk.device"), !deviceID.isEmpty,
              let userID = defaults.string(forKey: "lk.user"), !userID.isEmpty else {
            throw failure(6, "App Group 中没有电脑地址或设备登记信息；请先打开主 App 完成初始化")
        }
        return (serverURL, deviceID, userID)
    }

    static func deviceView(serverURL: String, deviceID: String) async throws -> DeviceMeetingView {
        guard var components = URLComponents(string: serverURL),
              deviceID.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
            throw failure(9, "设备查询地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.devicePath(
            SessionControlContract.deviceViewPathTemplate, deviceID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(9, "设备查询地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(9, "电脑端会议查询失败")
        }
        return try JSONDecoder().decode(DeviceMeetingView.self, from: data)
    }

    static func fetchArtifact(serverURL: String, meetingID: String,
                              deviceID: String) async throws -> (sha256: String, data: Data) {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(11, "报告地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.artifactPathTemplate, meetingID)
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        guard let endpoint = components.url else { throw failure(11, "报告地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["meeting_id"] as? String == meetingID,
              let sha256 = object["sha256"] as? String, sha256.count == 64,
              let report = object["report"] as? [String: Any],
              let encoded = object["report_json_base64"] as? String,
              let reportBytes = Data(base64Encoded: encoded),
              let verifiedReport = try? JSONSerialization.jsonObject(with: reportBytes) as? [String: Any],
              NSDictionary(dictionary: verifiedReport).isEqual(to: report),
              SHA256.hash(data: reportBytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw failure(11, "报告尚未生成或回包无效")
        }
        return (sha256, data)
    }

    static func acknowledgeArtifact(serverURL: String, meetingID: String,
                                    deviceID: String, sha256: String) async throws {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(12, "报告回执地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.artifactAckPathTemplate, meetingID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(12, "报告回执地址无效") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": deviceID, "sha256": sha256
        ])
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端未确认报告送达")
        }
    }

    static func requestBroadcastGrant() async throws -> MeetingGrant {
        // A previous ReplayKit process may have been killed before its stop HTTP request finished.
        // Resolve that stop before starting a new generation of the same channel.
        try await flushPendingBroadcastStop()
        let registration = try sharedRegistration()
        let identity = registration.deviceID + "-replaykit"
        let grant = try await requestGrant(serverURL: registration.serverURL,
                                           identity: identity,
                                           userID: registration.userID,
                                           deviceID: registration.deviceID,
                                           channel: SessionControlContract.systemAudio)
        return grant
    }

    static func stopChannel(serverURL: String, meetingID: String,
                            deviceID: String, channel: String,
                            generation: Int? = nil,
                            requestID: String = UUID().uuidString.lowercased()) async throws {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(7, "停止会议参数无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.stopPathTemplate, meetingID)
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(7, "停止会议地址无效") }
        guard channel == SessionControlContract.mic ||
              channel == SessionControlContract.systemAudio else {
            throw failure(7, "采集通道无效")
        }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
            var payload: [String: Any] = [
                "request_id": requestID,
                "device_id": deviceID,
                "channel": channel
            ]
            if let generation { payload["generation"] = generation }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure(8, "电脑端未确认会议停止")
            }
        }
    }

    static func queueBroadcastStop(serverURL: String, meetingID: String, deviceID: String,
                                   generation: Int) throws {
        try queueStop(serverURL: serverURL, meetingID: meetingID,
                      deviceID: deviceID, channel: SessionControlContract.systemAudio,
                      generation: generation,
                      key: pendingStopKey)
    }

    static func queueMicStop(serverURL: String, meetingID: String, deviceID: String,
                             generation: Int) throws {
        try queueStop(serverURL: serverURL, meetingID: meetingID,
                      deviceID: deviceID, channel: SessionControlContract.mic,
                      generation: generation,
                      key: pendingMicStopKey)
    }

    private static func queueStop(serverURL: String, meetingID: String, deviceID: String,
                                  channel: String, generation: Int, key: String) throws {
        guard let defaults = sharedDefaults() else {
            throw failure(13, "App Group 不可用，无法保存停止请求")
        }
        if let data = defaults.data(forKey: key),
           let existing = try? JSONDecoder().decode(PendingStop.self, from: data),
           existing.meetingID == meetingID && existing.deviceID == deviceID &&
           existing.channel == channel && existing.generation == generation {
            clearPendingStart(channel: channel, deviceID: deviceID)
            return // Keep the idempotency key across retries and extension shutdown races.
        }
        let pending = PendingStop(serverURL: serverURL, meetingID: meetingID,
                                  deviceID: deviceID, channel: channel,
                                  requestID: UUID().uuidString.lowercased(),
                                  generation: generation)
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
        defaults.synchronize()
        clearPendingStart(channel: channel, deviceID: deviceID)
    }

    private static func pendingStartKey(_ channel: String) throws -> String {
        switch channel {
        case SessionControlContract.mic: return pendingMicStartKey
        case SessionControlContract.systemAudio: return pendingBroadcastStartKey
        default: throw failure(7, "采集通道无效")
        }
    }

    private static func pendingStartID(serverURL: String, userID: String,
                                       deviceID: String, channel: String) throws -> String {
        guard let defaults = sharedDefaults() else {
            throw failure(13, "App Group 不可用，无法保存会议申请")
        }
        let key = try pendingStartKey(channel)
        if let data = defaults.data(forKey: key) {
            let pending = try JSONDecoder().decode(PendingStart.self, from: data)
            guard pending.serverURL == serverURL, pending.userID == userID,
                  pending.deviceID == deviceID, pending.channel == channel else {
                throw failure(15, "存在待恢复的旧会议申请，请先恢复原设备登记")
            }
            return pending.requestID
        }
        let pending = PendingStart(serverURL: serverURL, userID: userID,
                                   deviceID: deviceID, channel: channel,
                                   requestID: UUID().uuidString.lowercased())
        defaults.set(try JSONEncoder().encode(pending), forKey: key)
        defaults.synchronize()
        return pending.requestID
    }

    private static func clearPendingStart(channel: String, deviceID: String) {
        guard let key = try? pendingStartKey(channel),
              let defaults = sharedDefaults(), let data = defaults.data(forKey: key),
              let pending = try? JSONDecoder().decode(PendingStart.self, from: data),
              pending.deviceID == deviceID else { return }
        defaults.removeObject(forKey: key)
    }

    static func flushPendingBroadcastStop() async throws {
        try await flushPendingStop(key: pendingStopKey)
    }

    static func flushPendingMicStop() async throws {
        try await flushPendingStop(key: pendingMicStopKey)
    }

    private static func flushPendingStop(key: String) async throws {
        guard let defaults = sharedDefaults(),
              let data = defaults.data(forKey: key) else { return }
        let pending = try JSONDecoder().decode(PendingStop.self, from: data)
        try await stopChannel(serverURL: pending.serverURL, meetingID: pending.meetingID,
                              deviceID: pending.deviceID, channel: pending.channel,
                              generation: pending.generation,
                              requestID: pending.requestID)
        // Another process may have replaced the record while this request was in flight.
        if defaults.data(forKey: key) == data {
            defaults.removeObject(forKey: key)
        }
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VoiceMemo.MeetingControl", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
