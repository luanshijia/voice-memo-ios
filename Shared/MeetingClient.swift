import Foundation
import CryptoKit

/// Control API client used by the main App. App Group data below is read only for migration compatibility.
/// The computer creates the meeting id and returns it with the media grant.
struct MeetingGrant: Decodable {
    var requestID: String? = nil // local correlation; never decoded from the server
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
        struct Channel: Decodable {
            let status: String
            let generation: Int?
        }
        let meetingID: String
        let status: String
        let channels: [String: Channel]
        /// 电脑端给的接回截止时刻：通道中断起点 + 恢复宽限。
        /// nil 有两种来源，两种都等价于「此刻没有截止线」：
        ///   ① 还没开始计时（总管没标 interrupted_pending）；
        ///   ② 旧版电脑端根本不发这个字段。
        /// 格式错误由控制回包契约拒绝；此处仅解析已校验的可选字段。
        let recoveryDeadline: Date?
        enum CodingKeys: String, CodingKey {
            case meetingID = "meeting_id", status, channels
            case recoveryDeadline = "recovery_deadline"
        }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            meetingID = try box.decode(String.self, forKey: .meetingID)
            status = try box.decode(String.self, forKey: .status)
            channels = try box.decode([String: Channel].self, forKey: .channels)
            recoveryDeadline = DeviceMeetingView.instant(
                try box.decodeIfPresent(String.self, forKey: .recoveryDeadline))
        }
    }
    /// 契约里的时刻一律是 UTC ISO-8601（毫秒）。带小数的解析器单独建一个,
    /// 不带小数的旧格式也试一次:两处都失败才返回 nil。
    static func instant(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
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

/// 已确认定稿的补取页:断线或回前台后按 seq 补齐,线上只发实时 final。
struct TranscriptPage: Decodable {
    let meetingID: String
    let epoch: String?
    let reset: Bool?
    struct Item: Decodable {
        let seq: Int
        let who: String
        let source: String
        let text: String
        let audioS: Double
        let gapS: Double?
        let ts: Double
        enum CodingKeys: String, CodingKey {
            case seq, who, source, text, ts
            case audioS = "audio_s", gapS = "gap_s"
        }
    }
    let items: [Item]
    let latest: Int
    let oldest: Int
    let truncated: Bool?
    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id", epoch, reset, items, latest, oldest, truncated
    }
}

enum MeetingClient {
    private struct PendingStart: Codable {
        let serverURL: String
        let userID: String
        let deviceID: String
        let channel: String
        let requestID: String
        let meetingID: String?
        var grantedMeetingID: String? = nil
        var grantedGeneration: Int? = nil
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

    /// 设备名/使用者的真值只在打包时注入,源码留占位。
    /// 读不到 key(未注入 / 在扩展包里)时回落到中性占位,不会崩也不会显示空。
    private static func infoValue(_ key: String, fallback: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // build setting 未配置时 Info.plist 里会留下字面量 "$(VM_DEFAULT_DEVICE)"。
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return fallback }
        return trimmed
    }

    static var defaultDeviceID: String { infoValue("VMDefaultDevice", fallback: "iphone") }
    static var defaultUserID: String { infoValue("VMDefaultUser", fallback: "owner") }

    static func sharedDefaults() -> UserDefaults? {
        for group in appGroupCandidates where
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
            if let defaults = UserDefaults(suiteName: group) { return defaults }
        }
        return nil
    }

    private static func pendingStore() throws -> PendingRequestStore {
        let oldRoots = appGroupCandidates.compactMap({
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }).map { $0.appendingPathComponent("pending-control", isDirectory: true) }
        return PendingRequestStore(root: try AppStorage.pendingRequestDirectory(),
                                   legacy: sharedDefaults(), legacyRoots: oldRoots)
    }

    private static func validatedResponse(_ data: Data, kind: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure(16, "控制回包不是 JSON 对象")
        }
        if let problem = SessionControlContract.responseProblem(kind, object: object) {
            throw failure(16, "控制回包不符合契约：\(problem)")
        }
        return object
    }

    static func credential() throws -> String {
        guard let token = UserDefaults.standard.string(forKey: "vm.deviceToken"),
              !token.isEmpty else {
            throw failure(10, "这台手机尚未登记设备凭据，请在设置中填写")
        }
        return token
    }

    static func requestGrant(serverURL: String, identity: String, userID: String,
                             deviceID: String, channel: String,
                             meetingID: String? = nil,
                             ttl: Int = 15 * 60) async throws -> MeetingGrant {
        guard channel == SessionControlContract.mic else {
            throw failure(7, "此客户端只允许申请手机麦克风通道")
        }
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
        let pending = try pendingStart(serverURL: serverURL, userID: userID,
                                       deviceID: deviceID, channel: channel,
                                       meetingID: meetingID)
        var payload: [String: Any] = ["request_id": pending.requestID,
                                      "user_id": userID, "device_id": deviceID,
                                      "channel": channel]
        if let meetingID = pending.meetingID { payload["meeting_id"] = meetingID }
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
            let errorCode = Self.controlErrorCode(from: data)
            throw failure(http.statusCode,
                          "电脑端拒绝会议申请(\(http.statusCode))\(body.isEmpty ? "" : ":" + body)",
                          controlErrorCode: errorCode)
        }
        var grant: MeetingGrant
        do {
            let object = try validatedResponse(data, kind: "grant")
            guard SessionControlContract.startRequiredFields.isSubset(of: Set(object.keys)) else {
                throw failure(4, "会议授权回包缺少契约字段")
            }
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
        grant.requestID = pending.requestID
        try pendingStore().transaction(try pendingStartKey(channel)) { data in
            guard let data, var saved = try? JSONDecoder().decode(PendingStart.self, from: data),
                  saved.requestID == pending.requestID else { return (data, ()) }
            saved.grantedMeetingID = grant.meetingID
            saved.grantedGeneration = grant.generation
            return (try JSONEncoder().encode(saved), ())
        }
        return grant
    }

    static func reportObservation(serverURL: String, meetingID: String, deviceID: String,
                                  channel: String, generation: Int,
                                  observed: String, requestID: String? = nil) async throws {
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(14, "电脑端未确认采集状态")
        }
        let confirmation = try validatedResponse(data, kind: "observation")
        guard confirmation["meeting_id"] as? String == meetingID else { throw failure(14, "采集回执会议号不一致") }
        if observed == "publishing", let requestID {
            try clearPendingStart(channel: channel, deviceID: deviceID, requestID: requestID)
        }
    }

    static func sharedRegistration() throws -> (serverURL: String, deviceID: String, userID: String) {
        let defaults = UserDefaults.standard
        guard
              let serverURL = defaults.string(forKey: "lk.url"), !serverURL.isEmpty,
              let deviceID = defaults.string(forKey: "lk.device"), !deviceID.isEmpty,
              let userID = defaults.string(forKey: "lk.user"), !userID.isEmpty else {
            throw failure(6, "本机没有电脑地址或设备登记信息；请先在设置页完成初始化")
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
        _ = try validatedResponse(data, kind: "device_view")
        let view = try JSONDecoder().decode(DeviceMeetingView.self, from: data)
        if let receiver = view.view {
            guard receiver.meetingID == view.meeting?.meetingID,
                  receiver.identity == deviceID + "-view",
                  let media = URL(string: receiver.url), media.scheme == "wss",
                  media.host?.caseInsensitiveCompare(components.host ?? "") == .orderedSame else {
                throw failure(9, "会议查看授权与设备或地址不一致")
            }
        }
        return view
    }

    static func fetchTranscript(serverURL: String, meetingID: String, deviceID: String,
                                after: Int, epoch: String? = nil) async throws -> TranscriptPage {
        guard UUID(uuidString: meetingID) != nil,
              var components = URLComponents(string: serverURL) else {
            throw failure(12, "补取地址无效")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = SessionControlContract.meetingPath(
            SessionControlContract.transcriptPathTemplate, meetingID)
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID),
                                 URLQueryItem(name: "after", value: String(max(0, after)))]
        if let epoch { components.queryItems?.append(URLQueryItem(name: "epoch", value: epoch)) }
        guard let endpoint = components.url else { throw failure(12, "补取地址无效") }
        var request = URLRequest(url: endpoint)
        request.setValue(try credential(), forHTTPHeaderField: "X-VM-Device-Token")
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端补取失败")
        }
        let object = try validatedResponse(data, kind: "transcript")
        guard SessionControlContract.transcriptRequiredFields.isSubset(of: Set(object.keys)) else {
            throw failure(12, "补取回包缺少契约字段")
        }
        let page = try JSONDecoder().decode(TranscriptPage.self, from: data)
        // latest < oldest 只可能来自坏回包;宁可这一轮不补,也不把乱序的字塞进屏幕。
        guard page.meetingID == meetingID, page.oldest >= 0, page.latest >= page.oldest,
              page.epoch == nil || UUID(uuidString: page.epoch!) != nil,
              page.items.allSatisfy({ $0.seq > 0 && $0.seq >= page.oldest && $0.seq <= page.latest &&
                  $0.audioS.isFinite && $0.audioS >= 0 && $0.ts.isFinite && $0.ts > 0 &&
                  ($0.gapS == nil || ($0.gapS!.isFinite && $0.gapS! >= 0)) }),
              Set(page.items.map(\.seq)).count == page.items.count else {
            throw failure(12, "补取回包不自洽")
        }
        return page
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(11, "报告尚未生成或回包无效")
        }
        let object = try validatedResponse(data, kind: "artifact")
        guard object["meeting_id"] as? String == meetingID,
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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure(12, "电脑端未确认报告送达")
        }
        let confirmation = try validatedResponse(data, kind: "artifact_ack")
        guard confirmation["meeting_id"] as? String == meetingID,
              confirmation["sha256"] as? String == sha256 else { throw failure(12, "报告回执版本不一致") }
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw failure(8, "电脑端未确认会议停止")
            }
            let confirmation = try validatedResponse(data, kind: "stop")
            guard confirmation["meeting_id"] as? String == meetingID else { throw failure(8, "停止回执会议号不一致") }
        }
    }

    /// 带号恢复被电脑端明确拒绝(旧会已封场,或这个号在电脑端已不存在)的判定。
    static func isClosedMeetingRefusal(_ error: Error) -> Bool {
        let code = (error as NSError).userInfo["controlErrorCode"] as? String
        return code == "recovery_meeting_closed" || code == "recovery_meeting_not_found"
    }

    private static func controlErrorCode(from data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = body["error"] as? String else { return nil }
        return code
    }

    /// 丢掉这个通道的待确认申请。
    /// 为什么必须丢:同一个通道会复用原 requestID 与原请求体(见 `pendingStart`),
    /// 不清就会把"带号恢复"那条请求原样重放,永远拿不到新会。
    static func discardPendingStart(channel: String, deviceID: String) throws {
        try clearPendingStart(channel: channel, deviceID: deviceID, discard: true)
    }

    static func retireClosedStart(channel: String, deviceID: String, meetingID: String) throws {
        try pendingStore().transaction(try pendingStartKey(channel)) { data in
            guard let data, let saved = try? JSONDecoder().decode(PendingStart.self, from: data),
                  saved.deviceID == deviceID,
                  saved.grantedMeetingID == meetingID || saved.meetingID == meetingID else { return (data, ()) }
            return (nil, ())
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
        try pendingStore().transaction(key) { data in
            if let data, let existing = try? JSONDecoder().decode(PendingStop.self, from: data),
               existing.serverURL == serverURL, existing.meetingID == meetingID,
               existing.deviceID == deviceID, existing.channel == channel,
               existing.generation == generation { return (data, ()) }
            let pending = PendingStop(serverURL: serverURL, meetingID: meetingID,
                deviceID: deviceID, channel: channel, requestID: UUID().uuidString.lowercased(),
                generation: generation)
            return (try JSONEncoder().encode(pending), ())
        }
        try clearPendingStart(channel: channel, deviceID: deviceID,
                              meetingID: meetingID, generation: generation)
    }

    private static func pendingStartKey(_ channel: String) throws -> String {
        switch channel {
        case SessionControlContract.mic: return pendingMicStartKey
        case SessionControlContract.systemAudio: return pendingBroadcastStartKey
        default: throw failure(7, "采集通道无效")
        }
    }

    private static func pendingStart(serverURL: String, userID: String,
                                     deviceID: String, channel: String,
                                     meetingID: String?) throws -> PendingStart {
        if let meetingID, UUID(uuidString: meetingID) == nil {
            throw failure(15, "待恢复会议号无效")
        }
        return try pendingStore().transaction(try pendingStartKey(channel)) { data in
            if let data {
                let pending = try JSONDecoder().decode(PendingStart.self, from: data)
                if pending.serverURL == serverURL, pending.userID == userID,
                   pending.deviceID == deviceID, pending.channel == channel {
                    return (data, pending) // replay the original id and fingerprint
                }
            }
            let pending = PendingStart(serverURL: serverURL, userID: userID, deviceID: deviceID,
                channel: channel, requestID: UUID().uuidString.lowercased(), meetingID: meetingID)
            return (try JSONEncoder().encode(pending), pending)
        }
    }

    private static func clearPendingStart(channel: String, deviceID: String,
                                          requestID: String? = nil, meetingID: String? = nil,
                                          generation: Int? = nil, discard: Bool = false) throws {
        try pendingStore().transaction(try pendingStartKey(channel)) { data in
            guard let data, let saved = try? JSONDecoder().decode(PendingStart.self, from: data),
                  saved.deviceID == deviceID else { return (data, ()) }
            let sameRequest = requestID != nil && saved.requestID == requestID
            let sameGrant = meetingID != nil && saved.grantedMeetingID == meetingID &&
                saved.grantedGeneration == generation
            return (discard || sameRequest || sameGrant ? nil : data, ())
        }
    }

    static func flushPendingBroadcastStop() async throws {
        try await flushPendingStop(key: pendingStopKey)
    }

    static func flushPendingMicStop() async throws {
        try await flushPendingStop(key: pendingMicStopKey)
    }

    private static func flushPendingStop(key: String) async throws {
        let store = try pendingStore()
        guard let data = try store.read(key) else { return }
        let pending = try JSONDecoder().decode(PendingStop.self, from: data)
        try await stopChannel(serverURL: pending.serverURL, meetingID: pending.meetingID,
                              deviceID: pending.deviceID, channel: pending.channel,
                              generation: pending.generation, requestID: pending.requestID)
        try store.transaction(key) { current in (current == data ? nil : current, ()) }
    }

    private static func failure(_ code: Int, _ message: String,
                                controlErrorCode: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let controlErrorCode { userInfo["controlErrorCode"] = controlErrorCode }
        return NSError(domain: "VoiceMemo.MeetingControl", code: code,
                       userInfo: userInfo)
    }
}
