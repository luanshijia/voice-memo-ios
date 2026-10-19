import Foundation

/// Shared control contract for the main App and ReplayKit extension.
/// The computer creates the meeting id and returns it with the media grant.
struct MeetingGrant: Decodable {
    let url: String
    let token: String
    let identity: String
    let ttl: Int
    let meetingID: String

    enum CodingKeys: String, CodingKey {
        case url, token, identity, ttl
        case meetingID = "meeting_id"
    }
}

struct DeviceMeetingView: Decodable {
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
    enum CodingKeys: String, CodingKey {
        case stateRevision = "state_revision", meeting, view
    }
}

enum MeetingControlClient {
    static let appGroupID = "group.com.luanshijia.voicememo"
    static let appGroupCandidates = [appGroupID, "group.com.luanshijia.voicememo.458RP2552K"]
    static let defaultServerURL = "wss://100.64.0.2:7443"
    static let defaultDeviceID = "iphone"
    static let defaultUserID = "owner"
    static let broadcastFile = "broadcast-livekit.json"

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
        components.path = "/v1/meetings/start"
        components.queryItems = [URLQueryItem(name: "identity", value: identity),
                                 URLQueryItem(name: "ttl", value: String(ttl))]
        guard let endpoint = components.url else {
            throw failure(2, "会议申请地址无效")
        }
        let payload: [String: Any] = ["request_id": UUID().uuidString.lowercased(),
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
              grant.ttl > 0, grant.ttl <= 24 * 3600 else {
            throw failure(5, "会议授权回包身份、会议号、地址或有效期无效")
        }
        return grant
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
        components.path = "/v1/devices/\(deviceID)/meeting"
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
        components.path = "/v1/meetings/\(meetingID)/artifact"
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
              object["report"] is [String: Any] else {
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
        components.path = "/v1/meetings/\(meetingID)/artifact/ack"
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
        let registration = try sharedRegistration()
        let identity = registration.deviceID + "-replaykit"
        let grant = try await requestGrant(serverURL: registration.serverURL,
                                           identity: identity,
                                           userID: registration.userID,
                                           deviceID: registration.deviceID,
                                           channel: "system_audio")
        return grant
    }

    static func stopChannel(serverURL: String, meetingID: String,
                            deviceID: String, channel: String) async throws {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(7, "停止会议参数无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/v1/meetings/\(meetingID)/stop"
        components.queryItems = nil
        guard let endpoint = components.url else { throw failure(7, "停止会议地址无效") }
        guard channel == "mic" || channel == "system_audio" else {
            throw failure(7, "采集通道无效")
        }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "request_id": UUID().uuidString.lowercased(),
                "device_id": deviceID,
                "channel": channel
            ])
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure(8, "电脑端未确认会议停止")
            }
        }
    }

    static func storeBroadcastGrant(_ grant: MeetingGrant) throws {
        guard let container = appGroupCandidates.compactMap({
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }).first else {
            throw failure(6, "App Group 不可用，无法交接广播授权")
        }
        let payload: [String: Any] = ["url": grant.url,
                                      "identity": grant.identity,
                                      "token": grant.token,
                                      "fetchedAt": Date().timeIntervalSince1970,
                                      "ttl": grant.ttl,
                                      "session": grant.meetingID]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: container.appendingPathComponent(broadcastFile), options: .atomic)
    }

    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VoiceMemo.MeetingControl", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
